# todos

## 0.1 goals

these should be done before the language is considered complete:

- [x] **predictable type inference and typechecker**
  - [X] needed to optimize bytecode generation (e.g., distinguish `table_get` vs `tuple_get`)
  - [X] needed for zerocost comptime type-checking, like picking the right loop iterator
  - [X] then, make struct layouts comptime

- [x] predictablw const behaviour
    even i don't know how it works.
  - [x] either get rid of it entirely or really make it work well
  - [ ] document what happens and when

- [x] **comptime test system**
  - [x] normal tests
  ```ruby
  test "test name" do
      assert!(:true)
  end
  ```
  - [ ] doctests (like elixir)
  ```ruby
  ## @doc 
  > double(n: positive number) -> n * 2
  >> double(2)
  (:ok, 4)
  >> double("hi")
  (:err, "arg 0 is not a positive number")

  returns @n multiplied by 2 for all positive numbers
  ##
  fn double(n: number) match n
  | x when x > 0 and number?(x) ok(x*2)
  | _ err("arg 0 is not a positive number")
  ```

- [ ] better ext interfaces
    - [ ] more functions exposed to c
    - [x] zig extension api

- [x] **repl**
  - [ ] live ast checking

- [ ] **decorator system**
  - especially for metamethods
  - `@defer` binding decorator for resource cleanup (maybe not)
    ```asm
    let a @defer(fn(x) x:close()) = io:open("f.txt") 
    ```

- [x] **macro enhancements**
    - [x] proc macros
  - [ ] pattern matching for macros
  - [ ] macros importable on compiler's side
    - [ ] clearly scope them instead of having them be global
          maybe just namespace and restrict based on current module name

- [x] established doc system
    - [x] doc comment system

## perf

### advanced io
- [x] async runtime
- [x] **poll** (any posix)
- [ ] **kqueue** (bsd and osx)
- [ ] **uring** (linux)
- [ ] struct Runtime as a configurer
    add default presets. that means, the entirety of the lookup could be marked as inline and, eventually, just folded into an enum lookup and handled by the type system. this could also mean builds with full abscense of Runtime at runtime (and maybe as a field in vm), if comptimed the right way
    - [ ] struct Runtime figure out the who-owns-what with the vm and runtime relation. maybe entrypoint owns one runtime that is then always shared,
but the runtime owns the string interner and other state theoretically shareable between vm instances?
    - [ ] lua does something equivalent to moving module_cache, debug_infos, bootstrap_globals from vm to runtime here. super cool and fast 
    - [ ] node has a scheduler there too but i dont really get it

## std expansion

### easy

- [ ] **expose zig code as stdlib**
  - [x] language's ast, assembly, lexer, and parser
  - [x] http client/server
  - [x] json parsing and generation
  - [x] build itself
  - [ ] simple key-value db with disk i/o
  - [ ] regex (wrap system's engine from c or maybe take lua's match)

### lang

- [ ] **bigints** - arbitrary precision arithmetic

- [ ] **zerocost**
  - [ ] `mean` keyword (or `btw`, `meanwhile`, `also`) - pure non-functional, executes side-effects and returns nothing
  `1 + mean(12) "hi"  # prints "hi", then returns 1 + 12`
  - [ ] `inspect` - print value with line number, return unchanged
  `1 + inspect(2) == 3`

## nice-to-have

### cli

- [ ] **cli polish**
  - [ ] hand-fuzz unwinding
    - [ ] when reflection exists, pull in anything that could be of use from a recovered VM state
  - [ ] hand-fuzz error spans
  - progress indicators
  - help text improvements

### build system

- [ ] **built-in build/task system**
    - [ ] something similar to zig possibly

    <details>

    package manager will use a global cache
    no lockfile for single script, only build.rv
    it pulls via https git (unless ssh or http explicitly specified)
    and versions based on git tags
    the manifest is stored in that repo, either as [undecided]
        manifest.ini or manifest.toml or a serialized revo table

    ```ini
    version = 0.0.1
    license = GPLv2
    author = me
    ```

    - in single file:
    ```elixir
    pkgs!(
        "github.com/if-not-nil/md-tcp",
        markdown_over_tcp "github.com/if-not-nil/md-tcp"
    )

    markdown_over_tcp:serve(6767)
    ```
    - in `build.rv`:
    ```ruby
    import!("build")

    build(fn(b) do
      b:license(:GPLv3)
      # could also specify as
      b:custom_license({
        # pulling in a copyleft lib will prevent you from building it on bundle and warn
        :copyleft,
        "MPL-2"
      })
      b:version("0.1.2")
      
      b:packages({
          {"@web", version: "0.1.2^"}
          
      })
      b:command("run", "run the server", (:Exec, "src/main.rv"))
      b:command("build", "build the server", (:Cmd, do
        b:ensure_dir("out")
        b:sync("static", "out/static")
        b:compile({
          whence = "src/main.rv",
          into = "out/main.rvo",
          # dump all compiled imports into ./out with respecting structure
          # packages will load from global cache
          imports = "out/" 
        })
      end))
    end)
    ```

    - in `build.rv` for a library
    ```ruby
    import!("build")

    build(fn(b) do
      b:license(:GPLv3)
      # could also specify as
      b:custom_license({
        # pulling in a copyleft lib will prevent you from building it on bundle and warn
        :copyleft,
        name = "MPL-2",
        text = """
        prod. lung notification

        provided as-is, no liability, do whatever you want, must specify
        everyone involved as "prod. alice, bob, ..." instead of "authors: ..."
        or "contributors: ..." or whatever
        """
      })
      b:version("0.1.2")
      b:packages({
          {"@web", version: "0.1.2^"}
      })
      # run this in a git hook
      b:command("manifest", "build the manifest", (:Cmd, do
        b:build_manifest("./manifest.ini")
      end))
    end)
    ```

    </details>
- [ ] **package resolution and paths**
    - [ ] mimic lua's system closely and document through tests (with edge cases)
- [ ] **`use` statement** - for importing and binding to scope
  ```asm
  use "json"
  io.parse("{1: 'hi'}")
  ```

## cool but optional

- [ ] **lisp** - parses tree nodes directly how the compiler sees them, looks just like the parser's
print functionality. not really a lisp in a tradition sense but looks fun to implement
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
