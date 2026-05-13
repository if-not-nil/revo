# revo
[homepage & docs](https://gills.pages.dev/revo)
| [learn](https://gills.pages.dev/revo/basics)
| [codeberg](https://codeberg.org/lung/revo)
| [github (mirror)](https://github.com/if-not-nil/revo)

**revo** is an expressive, dynamically-typed language that is made\
to balance semantic freedom and readability

see [homepage](https://gills.pages.dev/revo) and [docs/basics](https://gills.pages.dev/revo/basics/)

- [installation](#installing)
- [cli reference](#cli-reference)
  - [development](#development)
  - [credits](#credits)

# installing
you will need [zig `0.16.0`](https://ziglang.org/download)

```bash
zig build -Doptimize=ReleaseFast
cp ./zig-out/bin/revo ~/.local/bin/revo
revo -h
```

binary releases not yet available

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
zig build -Doptimize=ReleaseFast # release built
zig build -Drepl=none # custom repl backend (bestline, readline, libedit, none)
```
the default repl backend is the vendored bestline, linked statically. read [build.zig](./build.zig)

### running tests

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
this greatly reduces maintenance burden

## credits

- [bestline](https://github.com/jart/bestline) by Justine Tunney - MIT

**optional repl backends, not vendored but linked dynamically**
- [libedit](https://thrysoee.dk/editline/) - BSD
- [GNU readline](https://tiswww.case.edu/php/chet/readline/rltop.html) - GPLv3
