# todos

## 1.0 requirements

these should be done before the language is considered complete:

- [ ] **predictable type inference and typechecker**
  - needed to optimize bytecode generation (e.g., distinguish `table_get` vs `tuple_get`)
  - needed for zerocost comptime type-checking, like picking the right loop iterator
  - then, make structs comptime and add go's interfaces

- [ ] **comptime test system**
  - normal tests
  ```ruby
  test "test name" do
    assert!(:true)
  end
  ```
  - doctests (like elixir)
  ```ruby
  ## @doc 
  returns @n multiplied by 2 for all positive numbers
  t> double(2)
  (:ok, 4)
  t> double("hi")
  (:err, "arg 0 is not a positive number")
  ##
  fn double(n: number) match n
  | x when x > 0 and number?(x) ok(x*2)
  | _ err("arg 0 is not a positive number")
  ```

- [ ] **repl**
  - live ast checking

- [ ] **decorator system**
  - especially for metamethods
  - `@defer` binding decorator for resource cleanup (maybe not)
    ```asm
    let a @defer(fn(x) x:close()) = io:open("f.txt") 
    ```

- [ ] **macro enhancements**
  - pattern matching for macros
  - importable macros with `use` statement
    - are currently always global

## perf

### advanced io
- [ ] **kqueue** (bsd and osx)
- [ ] **uring** (linux)
- [ ] struct Runtime as a type
    add default presets. that means, the entirety of the lookup could be marked as inline and, eventually, just folded into an enum lookup and handled by the type system. this could also mean builds with full abscense of Runtime at runtime (and maybe as a field in vm), if comptimed the right way
- [ ] struct Runtime figure out the who-owns-what with the vm and runtime relation. maybe entrypoint owns one runtime that is then always shared,
    but the runtime owns the string interner and other state theoretically shareable between vm instances?
- [ ] move more state into the global scope

## std expansion

### easy

- [ ] **expose zig code as stdlib**
  - language's ast, assembly, lexer, and parser
  - http client/server
  - json parsing and generation
  - simple key-value db with disk i/o
  - regex (wrap system's engine from c or maybe take lua's match)

### lang

- [ ] **bigints** - arbitrary precision arithmetic

- [ ] **language features**
  - `defer` statement (maybe not)
  - better forloops with captures:
    - `for {1,2,3} |el| print(el)`
    - `for {1,2,3}, 0..10 |el, i| print(i, el)`
    - `while i<10 : (i--) print(i)`

- [ ] **zerocost**
  - `mean` keyword (or `btw`, `meanwhile`, `also`) - pure non-functional, executes side-effects and returns nothing
    `1 + mean(12) "hi"  # prints "hi", then returns 1 + 12`
  - `inspect` - print value with line number, return unchanged
     `1 + inspect(2) == 3`

## nice-to-have

### cli

- [ ] **cli polish** - match the quality/aesthetics of bun
  - better error messages
  - progress indicators
  - help text improvements

### build system

- [ ] **built-in build/task system** - similar to bun, deno, or cargo
- [ ] **package resolution and paths** - dependency management
- [ ] **`use` statement** - for importing and binding to scope
  ```asm
  use "json"
  io.parse("{1: 'hi'}")
  ```

## cool but optional

- [ ] **lisp** - parses tree nodes directly how the compiler sees them, looks just like the parser's
    print functionality. not really a lisp in a tradition sense but looks fun to implement
- [ ] rewrite docgen.py in revo (long way to go)
- [ ] **reconstruct syntax from ast**

## done

- [x] distinct single and double quotes
- [x] string escaping with backslash
- [x] for loops
  - [x] numeric for loops
- [x] while loops
- [x] structs (abstractions over tuples)
- [x] compile-time evaluation
  - [x] comptime closures (isolated vms)
  - [x] automatic constant folding
- [x] no nil just atoms
- [x] default metamethods for built-in data types
- [x] go-style channels
- [x] save bytecode to disk
- [x] bytecode compilation flag (`-b`)
- [x] custom bytecode output path (`-o`)

## known issues

### docs

- [ ] document when/where `:nil`, `:undef`, and other special atoms are used
