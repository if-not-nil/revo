# revo
> a horse of a different color

[homepage](https://gills.pages.dev/revo)
| [learn](https://gills.pages.dev/revo/basics)
| [codeberg](https://codeberg.org/lung/revo)
| [github (mirror)](https://github.com/if-not-nil/revo)
| [license (REVO-GPLv3)](#license), not GPL-compatible

**revo** is an expressive, dynamically-typed language that is made\
to balance semantic freedom and readability

more on the [homepage](https://gills.pages.dev/revo)

## about

### core features

- **everything is an expression** - even assignments
```ruby
let a = let b = 5 # both are 5
```
- **predictable syntax** - if statements, matches, functions, etc. all can be reasoned about via expression sematics
```ruby
let s = 10
let e = 50 * (loop break(2))
if :true do # a do block groups multiple expressions together but is never required
    for x in s..e
        print(x)
end
```
- **pattern matching** - destructure tuple patterns in match or via `let (a, b) = (1, 2)`
```ruby
fn double(n: number) match n
| x when x > 0 and number?(x) ok(x*2)
| _ err("arg 0 is not a positive number")
```
- **macros** - comptime code generation
```ruby
const ok = macro `(%what:expr)` `(:ok, %what)`
ok(5) == (:ok, 5)
```
- **first-class functions** - closures, higher-order functions
```ruby
# the two following expressions are the same
fn a() :true
const a = fn() :true
```
- **no nil by default** - use atoms like `:nil`, `:undef` instead. booleans are `:true` and `:false` as well
```ruby
const t = {1,2,3}
const res = read():unwrap()
t[42] == :undef
do end == :nil
```
- **errors as values** - errors are first-class rather than exceptions
- **metatables** - oop without oop, sort of like lua
```ruby
let me = {name = "me", age = 42}
set_metatable(me, {
    __add = fn(self, other) return self.age + other,
    __mul = fn(self, other) return self[:age] * other # table keys are atoms
})
```

### concurrency

- **fibers/coroutines** - lightweight concurrency
```ruby
const a = spawn fn() "hi"
print(join(a))
```
- **go-style channels** - csp-based message passing
```ruby
const ch = chan()

spawn fn() do
  send(ch, "hello")
end

print(ch:recv()) # "hello"
```

### performance

compiles scripts to bytecode and tries to take full advantage of that 
```ruby
# revo -b ./src.rv builds, executes the comp blocks, and bakes them into the final
# program but does not run anything non-comp
const name = comp read()

# macros are expanded at compile time and are zero-cost
const print! = macro `(%fmt:str %ARGS(, %arg:expr)*)` `(print(fmt(%fmt %ARGS(, %arg))))`
print!("hi, %v", name)

# these are runtime for now, but will become comptime when a type system exists
struct Counter {
    count: number = 0
    const inc   = fn(self) do self.count += 1  self.count end
    const value = fn(self) self.count
}
```

### syntax

```ruby
# pattern matching
const res = read()

match res
| (:ok, v) print("ok: ", v)
| (:err, e) panic(e)
| _ panic("unwrap on non-result value")

for x, y in 0..10
  print(x, y)
end

let step = 1
const increment = fn(n) do n + step end
const result = (loop break 5) + 1 # 5

const value = if condition 5 else 2
```

## quick start

### install

the only dependency is [zig](https://ziglang.org/):
```bash
zig build
```

the binary will be available at `zig-out/bin/revo` or you can run with `zig build run`
### basic usage

```bash
revo script.rv # run script
revo -e "1 + 2" # inline code
revo -b script.rv              # creates script.rvo
revo -b -o output.rvo script   # custom output path
revo # start repl (not yet stable)
     # note: repl starts from a fresh source every time
     # this means, only your globals are preserved
revo --dis script.rv # bytecode disassembly
```

### cli reference

```help
usage: revo [options] [script [args...]]

options:
  -e code          run code
  -i               enter interactive mode after executing
  -b               compile script to bytecode (.rvo)
  -o path          output path for -b (default: input with .rvo extension)
  --dis            show bytecode disassembly instead of running
  -h, --help       show this help message
  --version        show version

examples:
  revo                           start interactive REPL
  revo script.rv                 run script
  revo -e "1 + 2"                run inline code
  revo -e "1 + 2" -i             run inline code and enter REPL
  revo -b script.rv              compile script to bytecode
  revo -b -o output.rvo script   compile script with custom output path
  revo --dis script.rv           show bytecode disassembly

revo uses a modified version of the GPLv3, refer to LICENSE.md
https://gills.pages.dev/revo/LICENSE.txt; sha256:415d4cce
```

## development

### building

```bash
zig build # debug build
zig build -Doptimize=ReleaseFast # release built
zig build -Drepl=none # custom repl backend (bestline, readline, libedit, none)
```

### running tests

```bash
zig build test --summary all -Dtest_filter="some test name filter"
```

### writing extensions in C
[see the docs](https://gills.pages.dev/revo/c)
```bash
zig build test --summary all -Dtest_filter="some test name filter"
```

### contributing

recommending to a friend is always greatly appreciated. any contributions are welcome!

see `TODO.md` for plans

if adding an std function, please add a doc-comment that can get parsed by `scripts/docgen.py`

please do not submit LLM-authored code if you do not understand it,\
can't explain it or have not tested it. describe the request in your own words,\
rather than pulling in a wall of AI-generated text.\
this greatly reducec maintenance burden

## license

revo is licensed under a modified GPLv3 license\
it is NOT compatible with article 10 of the GPLv3

see `LICENSE.txt`

## credits

- [bestline](https://github.com/jart/bestline) by Justine Tunney - MIT

**optional repl backends, not vendored but linked dynamically**
- [libedit](https://thrysoee.dk/editline/) - BSD
- [GNU readline](https://tiswww.case.edu/php/chet/readline/rltop.html) - GPLv3

## author

created by lung [codeberg](https://codeberg.org/lung)/[github](https://github.com/if-not-nil)
