# `revo, the programming language

[homepage & docs](https://revo.lung.fyi)
| [introduction & learn](https://revo.lung.fyi/docs)
| [playground](https://revo.lung.fyi/ide)
| [source & issues](https://github.com/if-not-nil/revo)
| [discuss & chat](https://discord.com/invite/XzGWh7TX59)

an expressive, dynamically-typed language for the joy of programming

> browser-runnable examples [here](https://revo.lung.fyi/docs)

<img width="692" height="796" alt="demo" src="https://github.com/user-attachments/assets/ed30f8ab-9f33-4a7d-9072-72c50912ce4b" />

![written in Zig](https://img.shields.io/badge/written%20in-Zig-orange) ![version 0.1.2](https://img.shields.io/badge/version-0.1.2-navy)

[tools](#tools)
| [editors](#editors)
| [credits](#credits)
| [examples](./examples)
| [made with revo](#made-with-revo)

## get

the latest release is hosted at [github releases](https://github.com/if-not-nil/revo/releases)

however, this project is rapidly changing. i recommend you build from source instead

## install from source

you need [zig](https://ziglang.org/download) `0.16.0` to build revo. i also recommend the [anyzig](https://github.com/marler8997/anyzig) version manager

### linux/bsd/mac/etc

```bash
git clone https://github.com/if-not-nil/revo --recursive && cd revo
git submodule update --init --recursive
zig build --fetch
zig build -Doptimize=ReleaseSafe
                  # =ReleaseSmall for a ~1mb executable
                  # =ReleaseFast  for a ~5%-10% performance gain (harder to report bugs on)
cp ./zig-out/bin/revo ~/.local/bin/revo

revo
```

#### nix

this project has a flake which exposes revo as a package on `default`. you can open a shell with revo using `nix shell git+https://github.com/if-not-nil/revo.git`. there is also a function that bundles a revo script into a nix package.

#### windows

> [!NOTE]
> some features are unavailable on windows. i recommend using WSL with the linux steps

```bash
git clone https://github.com/if-not-nil/revo && cd revo
zig build --fetch -Doptimize=ReleaseFast

mkdir "C:/tools/revo/bin"
copy ./zig-out/bin/revo C:/tools/revo/bin

# now add it to PATH by doing:
# - Win+S -> `env` -> <Enter> -> "Environment Variables" -> "Path" -> "System Variables"
# - add new at "C:\tools\revo\bin" -> click ok -> reopen your terminal

revo
```

### tools

- `lsp`

  diagnostics, highlighting, etc. in your editor!\
  bundled by default with your revo\
  [how to use in your text editor](./src/lsp/README.md)

- `tree-sitter`

  gives most editors revo syntax highlighting support
  [doomy/tree-sitter-revo on codeberg](https://codeberg.org/doomy/tree-sitter-revo)

- `docs`

  output docs in plaintext/html

  ```text
  revo doc <file or directory>
  revo doc --html <file or directory>
  ```

### editors

- [`vs code`](https://revo.lung.fyi/editors/#vscodecode-osscodium)
- [`neovim`](https://revo.lung.fyi/editors/#neovim)
- [`helix`](https://revo.lung.fyi/editors/#helix)
- `emacs`
  there is a literate emacs plugin with setup instructions at [Emacs.org](https://github.com/if-not-nil/revo/blob/main/Emacs.org)

### made with revo

- [hachem-wtf/revel](https://github.com/hachem-wtf/revel) -- a unix-like kernel
- if you want to feature your project on the readme, you can submit a project via issues/discussion/email/discord

### in c/zig/odin/what have you

you can extend revo in (essentially) any language or embed it from any language

there are two APIs for two ABIs:

- zig: [loadable extensions](https://github.com/if-not-nil/revo/tree/main/examples/foreign/zig) | todo: embedding
- c: [loadable extensions](https://github.com/if-not-nil/revo/tree/main/examples/foreign/c) | todo: embedding

### credits

revo is licensed as [MIT](./LICENSE.txt)

~ [isocline](https://github.com/daanx/isocline) by daanx - MIT\
~ [lsp-kit](https://github.com/zigtools/lsp-kit) by the zigtools team - MIT
