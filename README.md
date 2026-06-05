# `revo, the programming language

  
[homepage & docs](https://gills.pages.dev/revo)
| [github](https://github.com/if-not-nil/revo)
| [learn](https://gills.pages.dev/revo/basics)
| [chat & discuss](https://discord.com/invite/XzGWh7TX59)

an expressive, dynamically-typed language for the joy of programming

![written in Zig](https://img.shields.io/badge/written%20in-Zig-orange)  ![version 0.0.1a](https://img.shields.io/badge/version-0.0.1a-navy)

- [introduction](#introduction)
- [installing](#installing)
  - [on posix systems](#on-posix-systems)
  - [windows](#windows)
- [usage](#usage)
- [development](#development)
- [credits](#credits)
- [license](#license)

# introduction

```ruby
# =======================
# everything is something
# =======================
let x = do # 15
    let y = 5 + 10
    y
end

# =====
# pipes
# =====
let x = "hello"
  |> _:upper()
  |> _:sub(1, 2)
  |> assert_eq("el")
  |> do
    let el = _
    "h" + el + "lo"
  end
  |> assert_eq("hello")
  |> fn(c)

# ===============================
# pattern matching & result types
# ===============================
fn safe_div(a, b)
  if b == 0 (:err, :DivByZero)
  else (:ok, a / b)

match safe_div(10, 2)
  | (:ok, v)  => print(v) # 5
  | (:err, e) => print(e)

# =============================================================
# seamless concurrency
# > write blocking code,
# > then make it non-blocking by putting `spawn` in front of it
# =============================================================
const h = spawn fn() add(20, 22)
join(h) # 42

let ch = chan()
fn worker(n) do
  if n == 6 do
    send(ch, :done)
    return n
  end
  sleep(n * 100)
  send(ch, n * 10)
end

for i in 0..7
  spawn worker(n)

loop match recv(ch)
  | :done => break :done 
  | x => print("got", x)

# ============================================================
# first-class testing
# > test blocks get compiled & ran with the `--test` flag only
# ============================================================

fn add(a, b) a + b
fn mul(a, b) a * b

test "mul works" expect_eq(add(21, 21), 42)?

suite "math" do
  const N = 20
  const check_mul(a, b)
    expect(mul(a + b) == a * b)

  test "addition" do
    expect(add(N, 22) == 42)?
    expect(add(20, 22) != 22)?
  end

  test "multiplication" do
    check_mul(6, 7)?
    check_mul(20, 22)?
  end
end
```

## simple embedding api

```c
#include "revo.h"

ErevoVM *vm = erevo_vm_create();
if (!vm) return 1;

ErevoProgram *program = erevo_compile(vm, "main.rv", "1 + 2");
if (!program) {
  puts(erevo_vm_last_error(vm));
  return 1;
}

ErevoData result;
if (!erevo_run(vm, program, &result)) {
  puts(erevo_vm_last_error(vm));
}

if (!erevo_eval(vm, "main.rv", "1 + 2", &result)) {
  puts(erevo_vm_last_error(vm));
}

erevo_program_destroy(program);
erevo_vm_destroy(vm);
```


# installing
binary releases are not yet available

you will need [the latest **stable** version of zig](https://ziglang.org/download) to build revo (`0.16.0` at the moment)

available on most package managers as `zig`

## on posix (linux/bsd/mac)

```bash
git clone https://github.com/if-not-nil/revo && cd revo
git submodule update --init --recursive
# or -Doptimize=ReleaseSmall for a smaller executable
zig build --fetch -Doptimize=ReleaseFast
cp ./zig-out/bin/revo ~/.local/bin/revo

# should output the version
revo --version
```

### repl

the default REPL backend is [isocline](https://github.com/daanx/isocline):
- repl history saved to `~/.revo_history`
- multi-line expressions are shift+enter or C-j
- tab completion for revo keywords, commands (`:q`, `:clear`, `:backend`), and stdlib modules
- go to matching brace with M-b
- ctrl+r for searching through history

you can also get a dumb backend by doing `-Drepl=none`

### packaging:
- AUR: `revo-git` ([info & pkgbuild](https://aur.archlinux.org/packages/revo-git))

## windows

```bash
git clone https://github.com/if-not-nil/revo && cd revo
zig build --fetch -Doptimize=ReleaseFast

mkdir "C:/tools/revo/bin"
copy ./zig-out/bin/revo C:/tools/revo/bin

# now add it to PATH by doing:
# - Win+S -> `env` -> <Enter>
# - click "Environment Variables" and then "Path" in the "System variables"
# - add new at "C:\tools\revo\bin"
#    , or put it in one of the existing ones, if you know what you're doing
# - press OK for all of the tabs you've opened
# after that, you have to open a new CMD/Powershell window for PATH changes to take effect

# verify installation
revo --version
```
*note - the windows version does not yet have an async backend or a full-featured line editor. the latter is the easiest to add, a windows contributor might want to take a look at [./src/repl.zig](./src/repl.zig)*

# usage

```bash
usage: revo [options] [script [args...]]

options:
  -e code          run code
  -i               enter interactive mode after executing
  -d               output the last value the program evaluated
  -b               compile script to bytecode (.rvo)
  -o path          output path for -b (default: input with .rvo extension)
  --test           run test blocks
  --bench[n]       run with performance counters ([n] iterations, 1 if not specified)
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
  revo --bench script.rv         run with performance counters
  revo --dis script.rv           show bytecode disassembly
```

## development

### building

```bash
zig build # debug build
zig build run # debug run (repl implementation is hardcoded to a very simple one)
zig build -Doptimize=ReleaseFast # release build
zig build -Drepl=none # minimal repl backend (isocline, none)
# build C library + auto-generated header
# check zig-out/include/, zig-out/lib/
zig build lib 
```

**note:** the C library and header are only built with `zig build lib`.
the auto-generated header is always in sync with exported functions, marked with `callconv("c")`

### running tests

```bash
zig build test --summary all 
# opt: -Dtest_filter="some test name filter"
```

### revolt (the language server)

revo ships an LSP server at `src/lsp/`. it handles diagnostics, go-to-definition, hover,
references, document symbols, and workspace symbols.

to build:

```bash
zig build lsp
```

the binary lands at `zig-out/bin/revolt`

#### neovim setup

```lua
vim.lsp.config('revolt', {
  cmd = { 'revolt' },
  filetypes = { 'rv' },
  root_markers = { 'lib.json', 'exe.json', '.git' },
})
vim.lsp.enable('revolt')
```

see [docs/lsp.md](src/lsp/README.md) for the full feature list, troubleshooting, and other editors

### contributing

recommending to a friend is always greatly appreciated. any contributions are welcome!

you can contribute via github, codeberg or via [emailing me a .patch](mailto:lung-notification@proton.me)

see [CONTRIBUTING.md](./CONTRIBUTING.md)

## credits

- [isocline](https://github.com/daanx/isocline) by daanx - MIT
- [lsp-kit](https://github.com/zigtools/lsp-kit) by the zigtools team - MIT

# license

revo is licensed under [MIT.](https://mit-license.org/) see the [LICENSE.txt](./LICENSE.txt) file for details
