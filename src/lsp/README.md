# revolt, the revo language server

the server builds on the great work done by the zls team, being [lsp-kit][#references]
- [supported features](#supported-features)
- [installation](#supported-features)
    - [neovim](#neovim)
    - [helix](#helix)

# installation

to build the server binary:

```bash
zig build lsp
```

the binary is then gonna be at `zig-out/bin/revolt`

if you know how to add an lsp to emacs/zed/vscode/flow/whatever, please make a pull request!

## neovim

compile the binary and put it somewhere in your path
if you don't want to do so, just change the cmd field to wherever it is

```lua
vim.lsp.config('revolt', {
  cmd = { 'revolt' },
  filetypes = { 'rv' },
  root_markers = { 'lib.json', 'exe.json', '.git' },
})

vim.lsp.enable('revolt')
```

to check the status for all lsps, do `:checkhealth vim.lsp`

if it dies on you, do `lsp restart revolt` or `lsp enable revolt`

if you encounter a bug, especially if it's a crash, add this to your config:

```lua
vim.lsp.log.set_level 'trace'
```

then open the logs via

```lua
:lua vim.cmd('tabnew ' .. vim.lsp.log.get_filename())
```

## helix

this is what i use
```toml
[[language]]
name = "revo"
file-types = ["rv"]
comment-tokens = "#"
indent = { tab-width = 2, unit = "  " }
language-servers = [ "revolt" ]
scope = "source.revo"

[language-server.revolt]
command = "revolt"
```

you might want to add a grammar entry for syntax highlighting

## supported features

- [DONE] textDocument/didOpen
- [DONE] textDocument/didChange
- [DONE] textDocument/didClose
- [DONE] textDocument/definition
- [DONE] textDocument/hover
- [DONE] textDocument/references
- [DONE] textDocument/documentSymbol
- [STUB] textDocument/completion
- [DONE] workspace/symbol
- [DONE] textDocument/publishDiagnostics
- [TODO] textDocument/publishDiagnostics
- [TODO] textDocument/willSaveWaitUntil
- [TODO] textDocument/formatting
- [TODO] textDocument/rename
- [TODO] textDocument/codeAction
    - [TODO] inline a function

# server logs

revolt logs to stderr at `debug` level. to see the raw LSP traffic, run
the server manually:

```bash
revolt --log-level=debug 2> /tmp/revolt.log
```

## testing

tests are in `src/lsp/test.py` using `pytest-lsp`. they spin up a real revolt process and
talk to it over stdio

to run them:

```bash
cd src/lsp
python -m venv .venv
source .venv/bin/activate
pip install pytest pytest-lsp lsprotocol
python -m pytest test.py -vs --tb=short
```

the test fixture hardcodes the server path to `zig-out/bin/revolt` so build the server first

the rest of the architecture docs are going to be in `src/lsp/readme.org`


# development
my only expertise in LSP development is reading through the spec, so any help is appreciated

## testing

the test suite is not gonna build it automatically or try to find it in your path
it's hardcoded to `../../zig-out/bin/revolt`

```bash
source .venv/bin/activate # maybe .fish or .ps1 
.venv/bin/python -m pip install pytest pytest-lsp
.venv/bin/python -m pytest test.py -v
```

but i personally tend to mess up and have tests go undiscovered

so you can use `-v`
also use `-s` to show stdout/stderr

```bash
.venv/bin/python -m pytest test.py -v --tb=short
```

# references

- [neovim lsp docs](https://neovim.io/doc/user/lsp/)
- [lsp specification](https://microsoft.github.io/language-server-protocol/)
- [zigtools/lsp-kit](https://github.com/zigtools/lsp-kit)
