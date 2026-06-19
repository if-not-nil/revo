```
p for planned,
? for maybe,
x for done
```

## 0.1 completeness

### core

- [ ] variable arguments in user code
- [ ] default function arguments
- [ ] ambient type declarations
  - [ ] maybe via ambient `.d.rv` declaration files that are not parse-only without side-effects?
- [x] predictable type inference and typechecker
  - [x] needed to optimize bytecode generation (e.g., distinguish `table_get` vs `tuple_get`)
  - [x] needed for zerocost comptime type-checking (e.g., picking the right loop iterator)
  - [x] struct layouts now comptime

### macros & metaprogramming

- [x] macro enhancements
  - [x] proc macros
  - [ ] crystal-ish macros
    - [x] quasiquoting
  - [x] macros importable on the compiler's side
    - [ ] clearly scoped instead of global: namespace and restrict based on current module name

### tests & docs

- [x] comptime test system
  - [x] normal tests
    ```ruby
    test "test name" do
        assert!(:true)
    end
    ```
  - [ ] doctests (like ex)
    ```ruby
    ## @doc
    > double(n: positive number) -> n * 2
    >> double(2)
    (:ok, 4)
    >> double("hi")
    (:err, "arg 0 is not a positive number")
    ##
    fn double(n: number) match n
    | x when x > 0 and number?(x) ok(x*2)
    | _ err("arg 0 is not a positive number")
    ```
- [x] doc comment system
- [ ] annotate more code (backwardly done after writing rn)

### standard library

- [x] clean up the standard library
  - [x] clear abstraction for defining functions together with their docs and type signatures
- [ ] split core/std
  - [ ] bundled libraries: `core` for zig code, `std` for revo code
  - [ ] move cold code into revo (slightly slower before jit, acceptable)
  - [ ] core libs: *(TBD)*
  - [ ] std libs: *(TBD)*

### extensions & interop

- [ ] better ext interfaces
  - [x] more functions exposed to c
  - [x] zig extension api
  - [ ] userdata type: raw memory area with no predefined operations
        wrap in a struct to define operations
- [ ] wrappers
  - [ ] spyware: wraps data/function and shows all available stats (`__index`, `__newindex`, `__call`, etc.)
  - [ ] `fn about(any)`: vm stores as much build-time information about everything as possible; exposed as a table

### repl

- [x] repl
  - [ ] live ast checking (not possible with isocline afaik)

## performance

### scheduler, async & i/o

- [ ] m:n thread mapping
- [ ] rewrite i/o
      if `Io.Evented` is complete and enough, none of this matters

- [x] async runtime
- [x] `poll` (any posix)
- [ ] `kqueue` (bsd and macos)
- [ ] `uring` (linux)
- [ ] `Runtime` struct as a configurer
  - [ ] add default presets; make the lookup `inline`-able and eventually fold into an enum + type system
  - [ ] move `module_cache`, `debug_infos`, `bootstrap_globals` from vm to runtime (a la lua)
  - [ ] scheduler (a la node): design tbd
- todo: universal individual build step access from within revo code

## std/core

### expose zig code as stdlib

- [x] language's ast, assembler, lexer, and parser
- [x] http client/server
- [x] json parsing and generation
- [x] build system itself
- [ ] simple key-value db with disk i/o
- [ ] regex (wrap system engine from c, or adapt lua's match)

### language features

- [ ] bigints
- [ ] zerocosts
  - [ ] `mean` keyword (or `btw`, `also`): pure side-effect, returns nothing, can be in any position
    ```
    1 + mean(12) "hi"  # prints "hi", returns 1 + 12
    ```
  - [ ] `inspect`: print value with debug info, return unchanged
    ```
    1 + inspect(2) == 3
    ```

## tooling

### cli

- [ ] break&fix unwinding
  - [ ] when reflection exists, pull useful data from a recovered vm state
- [ ] break&fix error spans
- [ ] progress indicators
- help command
    - [ ] docs for zig functions
          may be irrelevant if all signatures move to ambient declaration files

### build system

- [ ] built-in build/task system (similar to zig)
  - package manager uses a global cache
  - no lockfile for single scripts, only `build.rv`
  - pulls via https git (unless ssh or http explicitly specified)
  - versions based on git tags
  - manifest stored in repo as `manifest.ini` / `manifest.toml` / serialized revo table *(undecided)*
  - see design notes below for single-file and `build.rv` examples

### lsp

- [ ] procedural per-project revo-defined code actions
  - [ ] `hooks:action()`: ast-transforming code actions
  - [ ] `hooks:format()`: custom format rules (node-level and document-level)
  - [ ] `hooks:completion()`: custom completion sources with trigger characters
  - [ ] `hooks:diagnostic()`: custom inline diagnostics
- [ ] optional style rules
  - [p] keep files below 80 lines
  - [?] any function with >80 lines must have a doc comment
  - [p] no `unwrap` or top-level `?`
- [ ] live ast checking in repl

## cool but optional

- [ ] lisp mode
- [ ] reconstruct syntax from ast
- [ ] untyped data
  java is fully typed, therefore it doesn't need to store data as typed
  when the type system is complete and 100% of revo code can be adequately typed, this should be possible

## apdx: build system design notes

<details>
<summary>single-file package usage</summary>

```ex
pkgs!(
    "github.com/if-not-nil/md-tcp",
    markdown_over_tcp "github.com/if-not-nil/md-tcp"
)

markdown_over_tcp:serve(6767)
```

</details>

<details>
<summary>build.rv for an application</summary>

```ruby
import!("build")

build(fn(b) do
  b:license(:GPLv3)
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
      imports = "out/"
    })
  end))
end)
```

</details>

<details>
<summary>build.rv for a library</summary>

```ruby
import!("build")

build(fn(b) do
  b:license(:GPLv3)
  b:version("0.1.2")
  b:packages({
      {"@web", version: "0.1.2^"}
  })
  b:command("manifest", "build the manifest", (:Cmd, do
    b:build_manifest("./manifest.ini")
  end))
end)
```

</details>
