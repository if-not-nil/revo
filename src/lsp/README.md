# revolt, the revo language server

the server builds on the great work done by the zls team, being [lsp-kit][#references]

- [supported features](#supported-features)
- [installation](#supported-features)
  - [neovim](#neovim)
  - [helix](#helix)

## installation

the LSP bundles into the `revo` binary itself - there is no standalone server binary.
run `revo lsp` to start it.

note: omit `lsp` from `-Dfeatures` to exclude it from any build

if you know how to add an lsp to emacs/zed/vscode/flow/whatever, please make a pull request!

### neovim

compile `revo` and put it somewhere in your path
if you don't want to do so, just change the cmd field to wherever it is

```lua
vim.lsp.config('revolt', {
  cmd = { 'revo', 'lsp' },
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

### helix

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
command = "revo"
args = ["lsp"]
```

you might want to add a grammar entry for syntax highlighting

### supported features

- [DONE] `textDocument/didOpen`
- [DONE] `textDocument/didChange`
- [DONE] `textDocument/didClose`
- [DONE] `textDocument/definition`
- [DONE] `textDocument/hover`
- [DONE] `textDocument/signatureHelp`
- [DONE] `textDocument/references`
- [DONE] `textDocument/documentSymbol`
- [DONE] `textDocument/rename`
  - [DONE] `textDocument/prepareRename`
- [STUB] `textDocument/completion`
- [DONE] `textDocument/publishDiagnostics`
- [DONE] `textDocument/inlayHint`
- [DONE] `textDocument/semanticTokens/full`
- [DONE] `workspace/symbol`
- [DONE] `textDocument/formatting`
  - `revo fmt`
- [DONE] `textDocument/willSaveWaitUntil`
  - same as `textDocument/formatting`
- [TODO] `textDocument/codeAction`
  - [TODO] inline a function
- [TODO] `textDocument/codeLens`

## server logs

the server logs to stderr at `debug` level. to see the raw LSP traffic, run
it manually:

```bash
revo lsp 2> /tmp/revo-lsp.log
```

### testing

tests are in `src/lsp/test.py` using `pytest-lsp`. they spin up a real lsp process and
talk to it over stdio

to run them:

```bash
cd src/lsp
python -m venv .venv
source .venv/bin/activate
pip install pytest pytest-lsp lsprotocol
python -m pytest test.py -vs --tb=short
```

the test fixture hardcodes the server path to `zig-out/bin/revo` (run with the `lsp` command) so build first

the rest of the architecture docs are going to be in `src/lsp/readme.org`

## development

my only expertise in LSP development is reading through the spec, so any help is appreciated

### testing

the test suite is not gonna build it automatically or try to find it in your path
it's hardcoded to `../../zig-out/bin/revo` (started with the `lsp` command)

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

## references

- [neovim lsp docs](https://neovim.io/doc/user/lsp/)
- [lsp specification](https://microsoft.github.io/language-server-protocol/)
- [zigtools/lsp-kit](https://github.com/zigtools/lsp-kit)
