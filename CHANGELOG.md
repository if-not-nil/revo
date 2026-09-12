# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

the table version `┬─┬ノ( º _ ºノ)`

tuples and structs are gone now, most breaking change yet

### Added

- structural table types: annotate tables by shape with `{ name: string, age: num }`
  - structs deprecated in favour of this, should be removed by 0.1.3
  - open subtyping: extra fields are ok, missing or mistyped fields are compile errors
  - field access on a structurally typed table infers the field's type
  - tracks both array and hash entries
  - positional array entries: `{num, num}` matches `{1, 2}`
    , mixed with named fields as `{num, num, name: string}`

  ```ruby
  fn greet(u: { name: string }) u.name
  greet({ name = "bob", age = 40 }) # "bob"
  ```

  - and the related lsp feats...
    - unknown-field diagnostics: reading `t.a` where every field of `t` is known
      and lacks `a` is now a compile error

      tables with unknown shapes are still ok though

    - lsp dot-completion for locals: `t.` completes record fields with types
      (analyzed from the buffer minus the incomplete access, which never parses)

    - lsp hover shows record field values: `t: {name: string = "me"}`
      for table literals instead of just the shape

    - lsp module hover lists macros: `pub proc`/`macro` decls show up
      in `a.` hover and completions; prelude macros no longer leak
      into dependency members with bogus lines

- just match
  sugar for `match :true`

    ```ruby
    match
    | :true => 5
    # => 5
    ```

- match table array patterns!
  keyless `{...}` in arm position destructures the array part
  keyed tables are still matched by equality

  ```ruby
  match {:ok, 42}
  | {:ok, v} => v
  | {:err, e} => 0
  # => 42
  ```

  they take `name: Type` ascriptions, checked per-arm:

  ```ruby
  match {1, "two"}
  | x: number => x * 2
  | {x, y: number} => x + y
  | {x, y} => y
  # => "two"
  ```

  the type gets narrowed, so `{:ok, v}` against
  `{:ok, num} | {:err, string}` binds `v: num`

  everything takes them

- table destructuring!

  ```ruby
  let {a, b} = {1, 2}
  print(a, b)
  # => 1 2
  ```

  these are the EXACT same patterns that go into matches\
  , so you can expect binds to work just as well:

  ```ruby
  let t = {1, {10}}
  let {a: number, {b}} = t

  a + b
  # => 11
  ```

- std:
  - `stats` module -- build a table for statistics
  - `frame` module -- dataframe-like structure
  - table methods: `get` with fallback, `empty?`, `update`, `deep_copy`,
    `slice`; `add` is gone, use `merge`
  - `hash(any) -> num`
  - `fs`:
    - `fs.open(path, mode?)`: mode is `"r"` (default, opens existing), `"w"`
      (creates or truncates), `"a"` (creates or keeps)
    - `fs.remove(path, recursive?)`: `:true` deletes the whole tree
    - `fs.mkdir(path, parents?, permissions?)`: `:true` creates missing parents like `mkdir -p`, replacing `fs.mkdirs`
    - `file.write(self, data, append?, permissions?)`: `:true` appends instead of overwriting, replacing `file.append`
    - `file.stat` / `fs.stat` take `follow?` (`:false` leaves symlinks alone, replacing `lstat`)
    - `fs.exists?` returns plain `bool` instead of `!bool`
    - `fs.touch(path)`, `fs.copy(src, dst)`

- c table api reworked around table values instead of ids:
  `get_idx`, `push`, `from_items`, name-keyed get/set, `revo_ok`/`revo_err`
  constructors with `is_ok`/`is_err`/`ok_value` checks; lookups report
  presence through the return value, `len`/`alen` split made explicit

### Removed

- struct type, `struct Name { ... }`, is gone
  `struct` is a plain identifier again
  use tables with closures instead: `{ name = "ana", greet = fn(self) ... }`

### Changed

- compound ops (`a -= 1`, `b += 2`, `c ^= 3`) are real now and will not call the lhs twice
- type-to-string rendering is unified
- rendered types use spaces
- internal
  - `.d.rv` simplified:
    - can now include type aliases
    - any `__` key now lands in a metatable automatically
    - macro prelude killed and put into `root.d.rv`

### Fixed

- host functions dropped explicit `:false` bool args: `unwrapArg` used `isBoolAtom` (true for both `:true`
  and `:false`) as the value instead of comparing against `:true`
- `promote.zig`'s `[8]Register` buffer was too small for `call_field`
  instructions with too many args
- `const x = import "raylib.so"` named imports now get the fields from the module's
  `.d.rv` manifest just like the normal `import "raylib.so"`
- lsp signatures show generics and optional params:
  `fn id[T](v: T) -> T`, `f(a: num, b?: num)` in hover and signature help
- `revo -e` no longer runs piped stdin as a program first, stdin stays available
  for `input()`, so `echo hi | revo -e 'input()?'` runs the inline code
- `join` nested inside a host call (eg `:map(fn(h) join h)`) waits by pumping
  the scheduler instead of falling through with the fiber handle
- `spawn` snapshots upvalues instead of sharing them, so fibers spawned in a
  `for` loop each see their own iteration value instead of all seeing the last
- `table` array parts hold 4 inline slots before spilling to the heap
  , so small tables skip array growth allocs and bulk appends size once instead of chaining

## [0.1.2] - 2026-09-05

big release - many misc bugs are fixed but not noted

### Added

- any function is a module

    ```ruby
    fn f() do
      pub const x = "valx"
      pub const a = 123
    end

    f() |> assert_eq({
      x = "valx",
      a = 123
    })
    ```

- docgen documents structs, type aliases, and modules, with documented struct fields rendered under the struct entry

  `revo doc` now outputs plaintext by default, `revo doc --html` outputs real html
  `--splice` flag needed to splice into piped markdown templates (was implied by `--html`)

    ```ruby
    #!/usr/bin/env revo
    this is a module doc
    a shebang can (but doesn't have to) go up there
        , it also suggests this file is executable
    !#
    #* this is a struct *#
    struct S {
      #* holds a number *#
      x: num,
    }

    #* 2 digits of precision *#
    const pi = 3.14
    ```

<img width="1018" height="925" alt="image" src="https://github.com/user-attachments/assets/69b74a23-c98e-4f4d-9b10-25c05631921c" />

- stdlib:
  - `exit(number)`
  - `revo.dofile(path)` -- do file & return; resole path like `import`
  - `csv.decode`, `csv.encode`
  - `os.getenv`, `os.setenv`
  - trig functions and sign in `math`
  - `argparse.parse`, `argparse.usage`: [docs & example](https://github.com/if-not-nil/revo/blob/main/examples/builtins/iter.rv)

      ```ruby
        const result = argparse.parse(fn(p) do
          p:flag(:verbose, { short = "v", description = "enable verbose output" })
          p:option(:output, { short = "o", description = "output file" })
          p:command(:compile, { description = "compile a file" })
          p:positional(:script, { description = "input script" })
        end, argv)

        if result.err do
          print("error:", result.err)
        end else do
          print("flags:", result.flags)
          print("commands:", result.commands)
          print("positionals:", result.positionals)
          print("leftover:", result.leftover)
          print("")
          print(argparse.usage(result))
        end
      ```

- default arguments

    ```ruby
       # vvvvv here
    fn f(a = 2, ?b) do
      (a, b)
    end; hi()
    # => (2, :none)
    ```

- semicolons act as boundaries

    ```ruby
    fn g() do
      foo = bar;
      (10, 11, 12)
    end; g()
    # was: tried to call bar(10, 11, 12) and assign that to foo
    # now: foo = bar; return (10, 11, 12)
    ```

- unless keyword

    ```ruby
    unless :true
        print("this won't run")
    else
        print("this will")
    ```

- zig extensions, examples for zig extensions (`examples/zig`)
- access tuple fields via dot: `(:a, :b).0 == :a`
- wider character range for atoms

    ```text
    :kebab-case
    :ok?
    :x>y?
    :name.method
    :a!=b
    :$jquery
    :-+*/=<>.@$~^?!
    ```

- `HACKING.md`
- `flake.nix`
- attribute syntax in the parser: `@[name]` lexes as an attribute and attaches to any declaration. will be used for applying procedural macros later
- repl now connected to the same architecture as the lsp, giving you richer highlighting

### Changed

- dunder methods now looked up through the normal order
- `table.remove(t, key)` -- now works with both indices (array part) and keys (hash part)
- **Breaking:** doc-comments are `#* ... *#` now, comments attach to any declaration and are stored in types, hover follows aliases, repl `:h` renders exactly what hover renders
- **Breaking:** cli is now subcommand-based: `compile`, `repl`, `dis`, `bench`, `docs`, `lsp`. options must come before the script name, everything after goes to runtime argv. the old flags like `-b` and `--dis` are gone in favor of their subcommands
- **Breaking:** c api values use nanbox: `RevoData` is a single u64 now, boxed payloads are intern ids instead of pointers
- **Breaking:** stdlib `read()` renamed to `input()`, and only reads stdin lines. use `fs.open()?:read()` to read files
- **Breaking:** `fmt` and string interpolation now only support `%v` (value, plain), `%?` (debug, quoted strings, multilined tables), `%p` (pretty, debug with colors)
- **Breaking:** `int`/`float`/`number` now `num` across everywhere. opcodes are gone too
- `Native` renamed to `Host` throughout the codebase
- lsp: fn return type hints, nested document symbols, parameter hover and param types in hover signatures
- semantic: top-level re-declarations shadow the module surface while fn-local bindings no longer leak into it; table methods written as `fn name(self)` inside a table literal get typed
- ...much more

### Fixed

- compiler: table literal entries declaring bindings reserved parent-frame registers mid-expression, clobbering the table under construction and desyncing enclosing call windows ("want table, got function"). declaring entries now compile in an isolated child frame, and keyless binding entries land in the array part instead of under the binding's name
- `orelse` falls through on `:undef`, so `t.missing orelse 0` works for absent table keys (GH-40)
- diagnostics expand tabs to tab stops before rendering carets, which no longer drift left on tab-indented lines (GH-36)
- stdlib `len()` signature corrected from `number|:nil` to `number`
- lsp signature help deep-copies parsed types so shared comptime sentinels can't dangle
- vm: table printing now consistent for `%v` `%?` `%p`; atom keys without `:`, ` = ` separator, multiline for debug/pretty when 2+ hash entries, pretty grouped array line, colored braces for empty
- vm: string escapes `\b` `\f` `\v` `\0` `\xXX` now rendered for non-printable bytes
- ...much more

## new contributors

- [gh:hachem-wtf](https://github.com/hachem-wtf) in <https://github.com/if-not-nil/revo/pull/45>
- [gh:Gingeh](https://github.com/Gingeh) in <https://github.com/if-not-nil/revo/pull/47>
- [cb:cstk](https://codeberg.org/cstk) in <https://codeberg.org/lung/revo/pulls/19>

**full changelog**: <https://github.com/if-not-nil/revo/compare/0.1.1...0.1.2>

> binaries are statically linked with musl when possible (this is why their sizes can reach >4mb). compile with `zig build -Doptimize=ReleaseSafe -Ddynamic` if you need a dynamically linked binary

## [0.1.1] - 2026-08-10

### Added

- string interpolation with `#{x}` syntax
- slicing: `"asdf"[2..]`, `{1, 2, 3, 4}[..3]`, `"hello"[4..-1..1]`
- freestanding wasm support, see the `wasm` directory for integrations
- new arithmetic operations: `//`, `^`, `xor`, and the rest of the binary operations
- lsp: hover, semantic tokens, completion for imports, symbol rename
- feature flags in zig build: `mimalloc`, `regex`
- stdlib module `re` for regex
- stdlib module `rng`
- stdlib module `compress`

### Changed

- reworked iterators
- mimalloc is generally better than the standard allocator
- general perf is ~1.5x faster via better codegen and micro-optimisations

## [0.1.0a] - 2026-07-24

### Added

- wasm builds, see `wasm/` dir
- result/error type syntaxes: `!T/U :== (:ok, T) | (:err, U)` and `!T :== (:ok, T) | (:err, any)`
- docgen for the std through `zig build docs`
- new std module: `compress`
- compiler return type propagation

[Unreleased]: https://github.com/if-not-nil/revo/compare/0.1.2...HEAD
[0.1.1]: https://github.com/if-not-nil/revo/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/if-not-nil/revo/compare/0.1.0a...0.1.1
[0.1.0a]: https://github.com/if-not-nil/revo/releases/tag/0.1.0a

**planned names:**
0.2.0 -- breakwater
0.3.0 -- the green version
