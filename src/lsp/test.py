import os
import tempfile
from pathlib import Path

import pytest
import pytest_lsp
from lsprotocol.types import (
    ClientCapabilities,
    CodeActionContext,
    CodeActionParams,
    CompletionParams,
    DefinitionParams,
    DidChangeTextDocumentParams,
    DidCloseTextDocumentParams,
    DidOpenTextDocumentParams,
    DocumentFormattingParams,
    DocumentSymbolParams,
    HoverParams,
    InlayHintParams,
    InitializeParams,
    Position,
    Range,
    ReferenceContext,
    PrepareRenameParams,
    ReferenceParams,
    RenameParams,
    SignatureHelpParams,
    TextDocumentContentChangeWholeDocument,
    TextDocumentIdentifier,
    TextDocumentItem,
    TextDocumentSaveReason,
    VersionedTextDocumentIdentifier,
    WillSaveTextDocumentParams,
    WorkspaceSymbolParams,
)
from pytest_lsp import ClientServerConfig, LanguageClient

REPO_ROOT = Path(__file__).resolve().parents[2]
REVOPLS = str(REPO_ROOT / "zig-out" / "bin" / "revo")
REVO_ARGS = ["lsp"]


@pytest_lsp.fixture(
    scope="module",
    config=ClientServerConfig(server_command=[REVOPLS] + REVO_ARGS),
)
async def client(lsp_client: LanguageClient):
    params = InitializeParams(capabilities=ClientCapabilities())
    await lsp_client.initialize_session(params)
    yield
    await lsp_client.shutdown_session()


TEST_URI = "file:///test/test.rv"
TEST_TEXT = """let x = 42

fn say_hi(name) do
  print("hello " + name)
end

print(say_hi("world"))
"""

DOC_URI = "file:///test/doc.rv"
DOC_TEXT = """#* greets a person by name *#
fn greet(name: string) -> string do
  "hello " + name
end

greet("world")
"""


@pytest.mark.asyncio(loop_scope="module")
async def test_clean_diagnostics(client: LanguageClient):
    """a file opens"""
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=TEST_URI,
                language_id="revo",
                version=1,
                text=TEST_TEXT,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(TEST_URI, [])
    for d in diags:
        print(f"  diag: {d.message} at {d.range}")
    assert len(diags) == 0, f"expected no diagnostics, got {
        len(diags)}: {[d.message for d in diags]}"


@pytest.mark.asyncio(loop_scope="module")
async def test_each_string_no_diag(client: LanguageClient):
    """`each("hello", fn(c) print(c))` is a valid stdlib call and
    wont wont raise a parse error"""
    uri = "file:///test/each.rv"
    text = 'each("hello", fn(c) print(c))\n'
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1, text=text,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(uri, [])
    for d in diags:
        print(f"  diag: {d.message!r} at {d.range}")
    assert len(diags) == 0, f"expected no diagnostics, got {
        len(diags)}: {[d.message for d in diags]}"


@pytest.mark.asyncio(loop_scope="module")
async def test_each_string_clean_after_typing(client: LanguageClient):
    """`each("hello", fn(c) print(c))` triggers an "unexpected token"
    while the user is mid-typing. once they finish, the diagnostic
    will clear"""
    uri = "file:///test/each_typing.rv"
    # do `fn)` with no params first, then
    # the full `fn(c) print(c))` form
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1,
                text='each("hello", fn)\n',
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags_mid = client.diagnostics.get(uri, [])
    print(f"  mid-typing: {len(diags_mid)}")
    # print("done")
    client.text_document_did_change(
        params=DidChangeTextDocumentParams(
            text_document=VersionedTextDocumentIdentifier(uri=uri, version=2),
            content_changes=[TextDocumentContentChangeWholeDocument(
                text='each("hello", fn(c) print(c))\n',
            )],
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags_final = client.diagnostics.get(uri, [])
    for d in diags_final:
        print(f"  final diag: {d.message!r} at {d.range}")
    assert len(diags_final) == 0, f"expected no diagnostics after fix, got {
        len(diags_final)}: {[d.message for d in diags_final]}"


@pytest.mark.asyncio(loop_scope="module")
async def test_each_string_no_diag_open(client: LanguageClient):
    """open a file containing only `each("hello", fn(c) print(c))` will have no
    typing history, no stale state and 0 diagnostics"""
    uri = "file:///test/each_open.rv"
    text = 'each("hello", fn(c) print(c))\n'
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1, text=text,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(uri, [])
    for d in diags:
        print(f"  diag: msg={d.message!r} code={d.code} range={d.range}")
    assert len(diags) == 0, f"expected no diagnostics, got {
        len(diags)}: {[(d.message, d.range) for d in diags]}"


@pytest.mark.asyncio(loop_scope="module")
async def test_definition(client: LanguageClient):
    """go to definition on `say_hi` call should point to `fn say_hi"""
    result = await client.text_document_definition_async(
        params=DefinitionParams(
            position=Position(line=6, character=6),
            text_document=TextDocumentIdentifier(uri=TEST_URI),
        )
    )
    assert result is not None, "unlucky"

    if isinstance(result, list):
        loc = result[0]
    else:
        loc = result

    assert loc.uri == TEST_URI
    # should point to `fn say_hi(name)` at line 2
    assert loc.range.start.line == 2


@pytest.mark.asyncio(loop_scope="module")
async def test_utf16_positions(client: LanguageClient):
    """positions are measured in the negotiated encoding (utf-16 default);
    multibyte chars before the cursor must not shift columns"""
    uri = "file:///test/utf16.rv"
    # line 2: `print("héllo") x` -> `x` is utf-16 col 15 but byte col 16
    text = 'print("héllo")\nfn f(a) a\nprint("héllo") f\n'
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1, text=text),
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")

    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=2, character=15),
            text_document=TextDocumentIdentifier(uri=uri),
        )
    )
    assert result is not None, "hover on f returned None"
    assert result.contents is not None
    assert "fn f" in result.contents.value, f"expected fn f hover, got: {
        result.contents.value}"
    assert result.range.start.line == 1
    assert result.range.start.character == 3, (
        f"definition should be at utf-16 col 3, got {
            result.range.start.character}"
    )

    loc = await client.text_document_definition_async(
        params=DefinitionParams(
            position=Position(line=2, character=15),
            text_document=TextDocumentIdentifier(uri=uri),
        )
    )
    assert loc is not None, "definition on f returned None"
    assert loc.range.start.line == 1
    assert loc.range.start.character == 3, (
        f"definition should be at utf-16 col 3, got {
            loc.range.start.character}"
    )


@pytest.mark.asyncio(loop_scope="module")
async def test_hover(client: LanguageClient):
    """hover over `x` should return information"""
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=0, character=4),
            text_document=TextDocumentIdentifier(uri=TEST_URI),
        )
    )
    print(result)
    assert result is not None, "hover is None"
    contents = result.contents
    assert contents is not None
    assert "number" in contents.value, "expected canonical type"


@pytest.mark.asyncio(loop_scope="module")
async def test_fn_hover(client: LanguageClient):
    """hover over a function should show its doc"""
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=TEST_URI,
                language_id="revo",
                version=1,
                text=TEST_TEXT,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=DOC_URI,
                language_id="revo",
                version=1,
                text=DOC_TEXT,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(DOC_URI, [])
    print(f"  doc diags: {len(diags)}")
    for d in diags:
        print(f"    msg={d.message!r} code={d.code} range={d.range}")

    # try hovering over `greet` at the definition
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=1, character=4),
            text_document=TextDocumentIdentifier(uri=DOC_URI),
        )
    )
    print("  hover result:", result)
    assert result is not None, "hover is None"
    contents = result.contents
    assert contents is not None
    print("  hover value:", repr(contents.value))
    assert "fn greet(name: string) -> string" in contents.value, "expected type signature with explicit return type"

    # try hovering over `say_hi` from TEST_URI to verify basic fn hover
    result2 = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=2, character=4),
            text_document=TextDocumentIdentifier(uri=TEST_URI),
        )
    )
    print("  say_hi hover:", result2)
    if result2 is not None:
        print("  say_hi value:", repr(result2.contents.value))

    # hover over `say_hi` in TEST_URI to verify basic fn hover works
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=2, character=4),
            text_document=TextDocumentIdentifier(uri=TEST_URI),
        )
    )
    print("say_hi hover:", result)
    assert result is not None
    contents = result.contents
    assert contents is not None
    print("  say_hi value:", repr(contents.value))
    assert "say_hi" in contents.value

    # hover over the call site `greet` should also show signature + doc
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=5, character=1),
            text_document=TextDocumentIdentifier(uri=DOC_URI),
        )
    )
    print(result)
    assert result is not None, "hover at call site is None"
    contents = result.contents
    assert contents is not None
    assert "fn greet(name: string) -> string" in contents.value, "expected type signature with explicit return type"
    assert "greets a person" in contents.value, "expected doc text at call site"


@pytest.mark.asyncio(loop_scope="module")
async def test_doc_inherits_through_alias(client: LanguageClient):
    """`const x = a` - hovering x shows a's doc"""
    uri = "file:///test/alias.rv"
    text = """#* the answer *#
pub const a = 5

const x = a

x
"""
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri,
                language_id="revo",
                version=1,
                text=text,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")

    # hover over `a` directly
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=1, character=10),
            text_document=TextDocumentIdentifier(uri=uri),
        )
    )
    assert result is not None, "hover on a is None"
    assert "the answer" in result.contents.value, f"expected doc on a, got: {
        result.contents.value!r}"

    # hover over `x`, which aliases `a`
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=3, character=6),
            text_document=TextDocumentIdentifier(uri=uri),
        )
    )
    print("alias hover:", result)
    assert result is not None, "hover on x is None"
    assert "the answer" in result.contents.value, f"expected inherited doc on x, got: {
        result.contents.value!r}"


@pytest.mark.asyncio(loop_scope="module")
async def test_manifest_hover(client: LanguageClient):
    """hover over a lib import typed by its .d.rv manifest"""
    import tempfile

    tmp = tempfile.TemporaryDirectory()
    try:
        with open(os.path.join(tmp.name, "extension.so"), "w"):
            pass
        with open(os.path.join(tmp.name, "extension.d.rv"), "w") as f:
            f.write("pub declare add = fn(a: number, b: number) -> number\n")
            f.write("pub declare concat = fn(parts: table, sep: string) -> string\n")
        uri = f"file://{tmp.name}/app.rv"
        script = 'import "extension.so"\nprint(extension.concat({"a", "b"}, "-"))\n'
        client.text_document_did_open(
            params=DidOpenTextDocumentParams(
                text_document=TextDocumentItem(
                    uri=uri,
                    language_id="revo",
                    version=1,
                    text=script,
                )
            )
        )
        await client.wait_for_notification("textDocument/publishDiagnostics")

        # hover over the module name
        result = await client.text_document_hover_async(
            params=HoverParams(
                position=Position(line=0, character=10),
                text_document=TextDocumentIdentifier(uri=uri),
            )
        )
        assert result is not None, "hover over module name is None"
        value = result.contents.value
        print("  module hover:", repr(value))
        assert "module `extension`" in value
        assert "concat" in value
        # content is a revo code block so the editor can highlight it
        assert "```revo" in value and value.index("```revo") < value.index("fn add"), \
            f"member sigs not in a revo fence: {value}"
        assert "- `fn" not in value, f"member bullets left in: {value}"
        # range covers just the module name in the import statement
        assert result.range is not None
        r = result.range
        print("  module hover range:", r)
        assert r.start.line == 0 and r.start.character == 8, f"expected name span, got: {
            r}"
        assert r.end.character == 17, f"expected name span, got: {r}"

        # hover over the member at the call site: signature from the manifest,
        # range covering just `concat` in the current file
        result = await client.text_document_hover_async(
            params=HoverParams(
                position=Position(line=1, character=21),
                text_document=TextDocumentIdentifier(uri=uri),
            )
        )
        assert result is not None, "hover over member is None"
        value = result.contents.value
        print("  member hover:", repr(value))
        assert "fn concat(parts: table, sep: string) -> string" in value, f"expected manifest sig, got: {
            value}"
        assert result.range is not None
        r = result.range
        print("  member hover range:", r)
        assert r.start.line == 1 and r.start.character == 16, f"expected call-site word span, got: {
            r}"
        assert r.end.character == 22, f"expected call-site word span, got: {r}"

        # signature help inside the member call
        sig = await client.text_document_signature_help_async(
            params=SignatureHelpParams(
                position=Position(line=1, character=24),
                text_document=TextDocumentIdentifier(uri=uri),
            )
        )
        print("  member signature help:", sig)
        assert sig is not None, "signature help over member call is None"
        label = sig.signatures[sig.active_signature].label
        assert label.startswith(
            "concat(") and "table" in label and "string" in label, f"expected manifest sig, got: {label}"

        # hover over the declared name inside the manifest file itself:
        # the range must cover just `zadd`, not the whole decl
        manifest_uri = f"file://{tmp.name}/extension.d.rv"
        with open(os.path.join(tmp.name, "extension.d.rv")) as f:
            manifest_text = f.read()
        client.text_document_did_open(
            params=DidOpenTextDocumentParams(
                text_document=TextDocumentItem(
                    uri=manifest_uri,
                    language_id="revo",
                    version=1,
                    text=manifest_text,
                )
            )
        )
        await client.wait_for_notification("textDocument/publishDiagnostics")
        name_col = manifest_text.index("add")  # `pub declare add = ...`
        result = await client.text_document_hover_async(
            params=HoverParams(
                position=Position(line=0, character=name_col + 1),
                text_document=TextDocumentIdentifier(uri=manifest_uri),
            )
        )
        assert result is not None, "hover over manifest decl is None"
        assert result.range is not None, f"hover over manifest decl has no range: {
            result}"
        r = result.range
        print("  decl hover range:", r)
        assert r.start.line == 0
        assert r.start.character == name_col, f"range must start at the name: {
            r}"
        assert r.end.character == name_col + \
            3, f"range must cover just the name: {r}"
    finally:
        tmp.cleanup()


@pytest.mark.asyncio(loop_scope="module")
async def test_signature_help(client: LanguageClient):
    """signature help should show params, types, and doc"""
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=DOC_URI,
                language_id="revo",
                version=1,
                text=DOC_TEXT,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")

    result = await client.text_document_signature_help_async(
        params=SignatureHelpParams(
            position=Position(line=5, character=6),
            text_document=TextDocumentIdentifier(uri=DOC_URI),
        )
    )
    assert result is not None, "signature help returned None"
    assert len(result.signatures) > 0, "expected at least one signature"
    sig = result.signatures[0]
    assert "greet" in sig.label, "expected function name in label"
    assert "name" in sig.label, "expected param name in label"
    assert "string" in sig.label, "expected type in label"
    assert sig.active_parameter == 0, "active param should be 0"
    assert sig.documentation is not None, "expected documentation"
    # documentation may be a string or a {string: ..., markup_content: ...} object
    doc_val = sig.documentation
    if isinstance(doc_val, dict):
        raw = doc_val.get("string") or doc_val.get(
            "markup_content", {}).get("value", "")
        assert "greets a person" in raw, f"expected doc text, got {doc_val}"
    elif isinstance(doc_val, str):
        assert "greets a person" in doc_val, f"expected doc text, got {
            doc_val}"
    else:
        # could be bytes/list, check raw
        raw = "".join(chr(b) if isinstance(b, int) else str(b)
                      for b in doc_val)
        assert "greets a person" in raw, f"expected doc text, got {raw}"


@pytest.mark.asyncio(loop_scope="module")
async def test_references(client: LanguageClient):
    """find references on `say_hi` should find def & call"""
    result = await client.text_document_references_async(
        params=ReferenceParams(
            position=Position(line=6, character=6),
            text_document=TextDocumentIdentifier(uri=TEST_URI),
            context=ReferenceContext(include_declaration=True),
        )
    )
    assert result is not None
    assert len(result) >= 2, f"expected >=2 refs, got {len(result)}"


@pytest.mark.asyncio(loop_scope="module")
async def test_document_symbols(client: LanguageClient):
    """document syms should list bindings and functions"""
    result = await client.text_document_document_symbol_async(
        params=DocumentSymbolParams(
            text_document=TextDocumentIdentifier(uri=TEST_URI),
        )
    )
    assert result is not None

    if isinstance(result, list):
        syms = result
    else:
        syms = result

    assert len(syms) >= 2
    names = [s.name for s in syms]
    assert "x" in names
    assert "say_hi" in names


@pytest.mark.asyncio(loop_scope="module")
async def test_workspace_symbol(client: LanguageClient):
    """workspace symbol should find 'say_hi'"""
    result = await client.workspace_symbol_async(
        params=WorkspaceSymbolParams(query="say_hi"),
    )
    assert result is not None
    assert len(result) >= 1
    names = [s.name for s in result]
    assert "say_hi" in names


@pytest.mark.asyncio(loop_scope="module")
async def test_did_change(client: LanguageClient):
    """changing file content should update diags"""
    client.text_document_did_change(
        params=DidChangeTextDocumentParams(
            text_document=VersionedTextDocumentIdentifier(
                uri=TEST_URI, version=2),
            content_changes=[
                TextDocumentContentChangeWholeDocument(text="let x = ")
            ],
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(TEST_URI, [])
    assert len(diags) > 0, "expected diagnostics for incomplete code"


@pytest.mark.asyncio(loop_scope="module")
async def test_undefined_name_single_diag(client: LanguageClient):
    """undefined name produces exactly 1 diagnostic with non-empty message"""
    uri = "file:///test/undefined.rv"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1, text="aaa\n",
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(uri, [])
    for d in diags:
        print(f"  diag: msg={d.message!r} code={d.code} range={d.range}")
    assert len(diags) == 1, f"expected 1 diagnostic for undefined name, got {
        len(diags)}: {[d.message for d in diags]}"
    assert len(diags[0].message) > 0, "diagnostic message should not be empty"
    assert "aaa" in diags[0].message, "message should reference the name"


@pytest.mark.asyncio(loop_scope="module")
async def test_unknown_field_diag(client: LanguageClient):
    """unknown field on a known-shape table gives u a diagnostic"""
    uri = "file:///test/unknown_field.rv"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1,
                text='let t = { name = "me" }\nt.a\n',
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(uri, [])
    for d in diags:
        print(f"  diag: msg={d.message!r} code={d.code} range={d.range}")
    assert len(diags) == 1, f"expected 1 diagnostic for unknown field, got {
        len(diags)}: {[d.message for d in diags]}"
    assert "a" in diags[0].message, "message should reference the field"


@pytest.mark.asyncio(loop_scope="module")
async def test_undefined_name_no_duplicates(client: LanguageClient):
    """same error from semantic+compile passes should not produce duplicates"""
    uri = "file:///test/undef_dup.rv"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1, text="bbb\n",
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(uri, [])
    for d in diags:
        print(f"  diag: msg={d.message!r} code={d.code} range={d.range}")
    # dedup by message+range: no two diagnostics should have the same pair
    seen = set()
    for d in diags:
        key = (d.message, d.range.start.line, d.range.start.character,
               d.range.end.line, d.range.end.character)
        assert key not in seen, f"duplicate diagnostic: {
            d.message} at {d.range}"
        seen.add(key)


@pytest.mark.asyncio(loop_scope="module")
async def test_multiple_errors_keep_own_messages(client: LanguageClient):
    """distinct errors show their own text, not the first error's"""
    uri = "file:///test/multi_err.rv"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1,
                text='let t = { name = "me" }\nt.a\nlet x: num = "hi"\n',
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(uri, [])
    for d in diags:
        print(f"  diag: msg={d.message!r} range={d.range}")
    assert len(diags) == 2, f"expected 2 diagnostics, got {
        len(diags)}: {[d.message for d in diags]}"
    assert any("not defined" in d.message for d in diags), (
        f"missing unknown-field text in {[d.message for d in diags]}")
    assert any("wants number" in d.message for d in diags), (
        f"missing mismatch text in {[d.message for d in diags]}")


@pytest.mark.asyncio(loop_scope="module")
async def test_close(client: LanguageClient):
    """closing a file doesnt crahs"""
    client.text_document_did_close(
        params=DidCloseTextDocumentParams(
            text_document=TextDocumentIdentifier(uri=TEST_URI),
        )
    )


COMPLETION_URI = "file:///test/completion.rv"
COMPLETION_TEXT = """let x = 42

fn say_hi(name) do
  print("hello " + name)
end

print(say_hi("world"))
"""


@pytest.mark.asyncio(loop_scope="module")
async def test_completion_basic(client: LanguageClient):
    """completion returns keywords + globals + locals"""
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=COMPLETION_URI,
                language_id="revo",
                version=1,
                text=COMPLETION_TEXT,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")

    result = await client.text_document_completion_async(
        params=CompletionParams(
            position=Position(line=0, character=0),
            text_document=TextDocumentIdentifier(uri=COMPLETION_URI),
        )
    )
    assert result is not None, "expected completions, got None"
    items = result.items if hasattr(result, 'items') else result
    labels = [i.label for i in items]
    assert "fn" in labels, f"expected 'fn' keyword in {labels}"
    assert "if" in labels, f"expected 'if' keyword in {labels}"
    assert "const" in labels, f"expected 'const' keyword in {labels}"
    # globals
    assert "print" in labels, f"expected 'print' in {labels}"
    assert "fmt" in labels, f"expected 'fmt' in {labels}"
    # locals from the file
    assert "x" in labels, f"expected 'x' in {labels}"
    assert "say_hi" in labels, f"expected 'say_hi' in {labels}"

    client.text_document_did_close(
        params=DidCloseTextDocumentParams(
            text_document=TextDocumentIdentifier(uri=COMPLETION_URI),
        )
    )


@pytest.mark.asyncio(loop_scope="module")
async def test_completion_prefix(client: LanguageClient):
    """completion filters by prefix"""
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=COMPLETION_URI,
                language_id="revo",
                version=1,
                text=COMPLETION_TEXT,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")

    # cursor inside `print`, if after `pri` then prefix is `pri`
    result = await client.text_document_completion_async(
        params=CompletionParams(
            position=Position(line=3, character=5),
            text_document=TextDocumentIdentifier(uri=COMPLETION_URI),
        )
    )
    assert result is not None
    items = result.items if hasattr(result, 'items') else result
    labels = [i.label for i in items]
    assert "print" in labels, f"expected 'print' in {labels}"
    # "pri" prefix should not match things like "fn" or "x"
    assert "fn" not in labels, f"'fn' should not match 'pri' prefix, got {
        labels}"
    assert "x" not in labels, "'x' should not match 'pri' prefix"

    client.text_document_did_close(
        params=DidCloseTextDocumentParams(
            text_document=TextDocumentIdentifier(uri=COMPLETION_URI),
        )
    )


@pytest.mark.asyncio(loop_scope="module")
async def test_completion_kinds(client: LanguageClient):
    """completion items have appropriate kind values"""
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=COMPLETION_URI,
                language_id="revo",
                version=1,
                text=COMPLETION_TEXT,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")

    # cursor at start of line 0 to get all completions
    result = await client.text_document_completion_async(
        params=CompletionParams(
            position=Position(line=0, character=0),
            text_document=TextDocumentIdentifier(uri=COMPLETION_URI),
        )
    )
    assert result is not None
    items = result.items if hasattr(result, 'items') else result
    kinds = {i.label: i.kind for i in items}
    # keywords should be kind=14 (Keyword)
    assert kinds.get("fn") == 14, f"'fn' should be Keyword kind (14), got {
        kinds.get('fn')}"
    assert kinds.get("if") == 14
    # functions should be kind=3 (Function)
    assert kinds.get("print") == 3, f"'print' should be Function kind (3), got {
        kinds.get('print')}"
    assert kinds.get("len") == 3
    # all kinds should be valid ints
    assert all(isinstance(v, int)
               for v in kinds.values()), "all kinds should be ints"

    client.text_document_did_close(
        params=DidCloseTextDocumentParams(
            text_document=TextDocumentIdentifier(uri=COMPLETION_URI),
        )
    )


@pytest.mark.asyncio(loop_scope="module")
async def test_table_destructuring_no_diag(client: LanguageClient):
    """`let {w1, w2} = {1, 2}` doesnt die"""
    uri = "file:///test/table_destructure.rv"
    text = "let {w1, w2} = {1, 2}\nprint(w1, w2)\n"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1, text=text,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    diags = client.diagnostics.get(uri, [])
    for d in diags:
        print(f"  diag: {d.message!r} at {d.range}")
    assert len(diags) == 0, f"expected no diagnostics, got {
        len(diags)}: {[d.message for d in diags]}"


@pytest.mark.skip(reason="TODO")
@pytest.mark.asyncio(loop_scope="module")
async def test_will_save_wait_until(client: LanguageClient):
    """will save wait until should allow edits before saving"""
    result = await client.text_document_will_save_wait_until_async(
        params=WillSaveTextDocumentParams(
            text_document=TextDocumentIdentifier(uri=TEST_URI),
            reason=TextDocumentSaveReason.Manual,
        ),
    )
    assert result is not None


@pytest.mark.skip(reason="TODO")
@pytest.mark.asyncio(loop_scope="module")
async def test_formatting(client: LanguageClient):
    """formatting should produce some edits"""
    result = await client.text_document_formatting_async(
        params=DocumentFormattingParams(
            text_document=TextDocumentIdentifier(uri=TEST_URI),
            options={"tabSize": 2, "insertSpaces": True},
        ),
    )
    assert result is not None


@pytest.mark.asyncio(loop_scope="module")
async def test_inlay_hints(client: LanguageClient):
    """inlay hints should show inferred types"""
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=TEST_URI, language_id="revo", version=1, text=TEST_TEXT,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    result = await client.text_document_inlay_hint_async(
        params=InlayHintParams(
            text_document=TextDocumentIdentifier(uri=TEST_URI),
            range=Range(start=Position(line=0, character=0),
                        end=Position(line=10, character=0)),
        ),
    )
    print("  inlay hints:", result)
    assert result is not None
    # `x` is `let x = 42` -> should have a type hint ": num"
    found_x = [h for h in result if h.position.line == 0]
    assert len(found_x) >= 1, f"expected hint for x, got hints: {result}"
    hint = found_x[0]
    assert "number" in hint.label, f"expected canonical type in label, got {
        hint.label}"
    assert hint.kind == 1  # InlayHintKind.Type = 1


@pytest.mark.asyncio(loop_scope="module")
async def test_rename(client: LanguageClient):
    """rename should update all references"""
    # re-open TEST_URI in case a previous test closed it
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=TEST_URI, language_id="revo", version=1, text=TEST_TEXT,
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")

    # first, prepareRename should confirm renameability
    prep = await client.text_document_prepare_rename_async(
        params=PrepareRenameParams(
            text_document=TextDocumentIdentifier(uri=TEST_URI),
            position=Position(line=2, character=3),
        ),
    )
    assert prep is not None, "prepareRename returned None"
    if hasattr(prep, 'range'):
        r = prep.range
    else:
        r = prep
    assert r.start.line == 2
    assert r.start.character <= 3 <= r.end.character

    # then rename should return a WorkspaceEdit
    result = await client.text_document_rename_async(
        params=RenameParams(
            text_document=TextDocumentIdentifier(uri=TEST_URI),
            position=Position(line=2, character=3),
            new_name="greet",
        ),
    )
    print("  rename result:", result)
    assert result is not None, "rename returned None"
    # should have changes with at least the current file
    assert result.changes is not None, "expected changes in workspace edit"


@pytest.mark.skip(reason="TODO")
@pytest.mark.asyncio(loop_scope="module")
async def test_code_action(client: LanguageClient):
    """code actions should include inline function"""
    result = await client.text_document_code_action_async(
        params=CodeActionParams(
            text_document=TextDocumentIdentifier(uri=TEST_URI),
            range={"start": {"line": 2, "character": 0},
                   "end": {"line": 4, "character": 3}},
            context=CodeActionContext(diagnostics=[]),
        ),
    )
    assert result is not None
    if result:
        titles = [a.title for a in result]
        assert any("inline" in t.lower() for t in titles)


ONE_RV_CONTENT = """pub fn hi(a: num, b: num) -> num
  a * b

pub const CT: int = 5
"""

TWO_RV_CONTENT = """import "one.rv"

one.hi(1, 2)
"""


def _open_import_pair(client: LanguageClient, tmpdir):
    one_path = os.path.join(tmpdir, "one.rv")
    with open(one_path, "w") as f:
        f.write(ONE_RV_CONTENT)

    two_path = os.path.join(tmpdir, "two.rv")
    with open(two_path, "w") as f:
        f.write(TWO_RV_CONTENT)

    one_uri = "file://" + one_path
    two_uri = "file://" + two_path
    client.text_document_did_open(params=DidOpenTextDocumentParams(
        text_document=TextDocumentItem(
            uri=one_uri, language_id="revo", version=1, text=ONE_RV_CONTENT),
    ))
    client.text_document_did_open(params=DidOpenTextDocumentParams(
        text_document=TextDocumentItem(
            uri=two_uri, language_id="revo", version=1, text=TWO_RV_CONTENT),
    ))
    return one_uri, two_uri


@pytest.mark.asyncio(loop_scope="module")
async def test_import_hover(client: LanguageClient):
    """hover over `hi` in `one.hi(1, 2)` should resolve through import"""
    with tempfile.TemporaryDirectory() as tmpdir:
        _, two_uri = _open_import_pair(client, tmpdir)
        await client.wait_for_notification("textDocument/publishDiagnostics")

        result = await client.text_document_hover_async(
            params=HoverParams(
                position=Position(line=2, character=4),
                text_document=TextDocumentIdentifier(uri=two_uri),
            )
        )
        print("  import hover result:", result)
        assert result is not None, "hover on imported fn returned None"
        contents = result.contents
        assert contents is not None
        assert "hi" in contents.value, f"expected 'hi' in hover, got: {
            contents.value}"
        assert "fn hi" in contents.value or "num" in contents.value, (
            f"expected fn signature in hover, got: {contents.value}"
        )


@pytest.mark.asyncio(loop_scope="module")
async def test_import_completion(client: LanguageClient):
    """completion after `one.` should show items from imported module"""
    with tempfile.TemporaryDirectory() as tmpdir:
        _, two_uri = _open_import_pair(client, tmpdir)
        result = await client.text_document_completion_async(
            params=CompletionParams(
                position=Position(line=2, character=4),
                text_document=TextDocumentIdentifier(uri=two_uri),
            )
        )
        assert result is not None, "expected completions, got None"
        items = result.items if hasattr(result, 'items') else result
        labels = [i.label for i in items]
        assert "hi" in labels, f"expected 'hi' completion from import, got: {
            labels}"


@pytest.mark.asyncio(loop_scope="module")
async def test_bare_import_completion_after_dot(client: LanguageClient):
    """typing `.` after a bare-imported module keeps completing its members
    (deps recorded while valid must survive the unparseable keystroke)"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmpdir:
        with open(os.path.join(tmpdir, "a.rv"), "w") as f:
            f.write('pub fn f() 10\npub let v = 5\n')

        user_path = os.path.join(tmpdir, "b.rv")
        user_uri = "file://" + user_path
        client.text_document_did_open(params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=user_uri, language_id="revo", version=1,
                text='import "a"\na'),
        ))

        await client.wait_for_notification("textDocument/publishDiagnostics")
        client.text_document_did_change(params=DidChangeTextDocumentParams(
            text_document=VersionedTextDocumentIdentifier(
                uri=user_uri, version=2),
            content_changes=[TextDocumentContentChangeWholeDocument(
                text='import "a"\na.')],
        ))

        await client.wait_for_notification("textDocument/publishDiagnostics")
        result = await client.text_document_completion_async(
            params=CompletionParams(
                position=Position(line=1, character=2),
                text_document=TextDocumentIdentifier(uri=user_uri),
            )
        )

        assert result is not None, "expected completions, got None"
        items = result.items if hasattr(result, 'items') else result
        labels = [i.label for i in items]
        assert "f" in labels, f"expected 'f' completion, got: {labels}"
        assert "v" in labels, f"expected 'v' completion, got: {labels}"


@pytest.mark.asyncio(loop_scope="module")
async def test_module_hover_shows_macros_not_prelude(client: LanguageClient):
    """module hover lists dep macros once, without prelude leakage"""
    with tempfile.TemporaryDirectory() as tmpdir:
        with open(os.path.join(tmpdir, "a.rv"), "w") as f:
            f.write(
                'pub let v = 5\n\npub fn f() 10\n\npub proc hi!(m) do\n\tm.items\nend\n')
        user_path = os.path.join(tmpdir, "b.rv")
        user_text = 'import "a"\na.hi!(:ok)\n'
        with open(user_path, "w") as f:
            f.write(user_text)
        dep_uri = "file://" + os.path.join(tmpdir, "a.rv")
        client.text_document_did_open(params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=dep_uri, language_id="revo", version=1,
                text='pub let v = 5\n\npub fn f() 10\n\npub proc hi!(m) do\n\tm.items\nend\n'),
        ))
        await client.wait_for_notification("textDocument/publishDiagnostics")
        user_uri = "file://" + user_path
        client.text_document_did_open(params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=user_uri, language_id="revo", version=1, text=user_text),
        ))
        await client.wait_for_notification("textDocument/publishDiagnostics")
        result = await client.text_document_hover_async(
            params=HoverParams(
                position=Position(line=1, character=0),
                text_document=TextDocumentIdentifier(uri=user_uri),
            )
        )
        assert result is not None, "hover on module name returned None"
        value = result.contents.value
        print("  module hover:", repr(value))
        assert "hi!" in value, f"expected macro in hover, got: {value}"
        assert "ok?!" not in value, f"prelude leaked into hover: {value}"
        assert value.count(
            "proc hi!(m) do") == 1, f"expected no duplicates, got: {value}"


@pytest.mark.asyncio(loop_scope="module")
async def test_record_hover_shows_values(client: LanguageClient):
    """hover over a table shows field types with literal values"""
    uri = "file:///test/record_hover.rv"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1,
                text='let t = {\n\tname = "me"\n}\nt\n',
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=3, character=0),
            text_document=TextDocumentIdentifier(uri=uri),
        )
    )
    assert result is not None, "hover returned None"
    value = result.contents.value
    print("  record hover:", repr(value))
    assert 't: {name: string = "me"}' in value, f"expected record with value, got: {
        value}"


@pytest.mark.asyncio(loop_scope="module")
async def test_local_table_completion(client: LanguageClient):
    """completion after `t.` should show record fields of the local"""
    uri = "file:///test/local_fields.rv"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1,
                text='let t = { name = "me", age = 30 }\nt.',
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    result = await client.text_document_completion_async(
        params=CompletionParams(
            position=Position(line=1, character=2),
            text_document=TextDocumentIdentifier(uri=uri),
        )
    )
    assert result is not None, "expected completions, got None"
    items = result.items if hasattr(result, 'items') else result
    labels = [i.label for i in items]
    print("  local completion labels:", labels)
    assert "name" in labels, f"expected 'name' completion, got: {labels}"
    assert "age" in labels, f"expected 'age' completion, got: {labels}"


@pytest.mark.asyncio(loop_scope="module")
async def test_table_method_hover(client: LanguageClient):
    """hover over a table with methods shows the method type"""
    uri = "file:///test/method_hover.rv"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1,
                text='let t = { name = "me", fn getName(self) self.name }\nt',
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=1, character=0),
            text_document=TextDocumentIdentifier(uri=uri),
        )
    )
    assert result is not None, "hover returned None"
    value = result.contents.value
    print("  method hover:", repr(value))
    assert "getName" in value, f"expected 'getName' in hover, got: {value}"
    assert "fn" in value, f"expected fn type in hover, got: {value}"


@pytest.mark.asyncio(loop_scope="module")
async def test_implicit_table_hover(client: LanguageClient):
    """hover over a table with implicit entries shows array fields"""
    uri = "file:///test/implicit_hover.rv"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1,
                text='let t = { 1, 2 }\nt',
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=1, character=0),
            text_document=TextDocumentIdentifier(uri=uri),
        )
    )
    assert result is not None, "hover returned None"
    value = result.contents.value
    print("  implicit hover:", repr(value))
    assert "number = 1" in value, f"expected 'number = 1' in hover, got: {
        value}"
    assert "number = 2" in value, f"expected 'number = 2' in hover, got: {
        value}"
    assert "number" in value, f"expected 'number' type in hover, got: {value}"


@pytest.mark.asyncio(loop_scope="module")
async def test_mixed_table_hover(client: LanguageClient):
    """hover over a table with both implicit and explicit entries"""
    uri = "file:///test/mixed_hover.rv"
    client.text_document_did_open(
        params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=uri, language_id="revo", version=1,
                text='let t = { 1, 2, name = "me" }\nt',
            )
        )
    )
    await client.wait_for_notification("textDocument/publishDiagnostics")
    result = await client.text_document_hover_async(
        params=HoverParams(
            position=Position(line=1, character=0),
            text_document=TextDocumentIdentifier(uri=uri),
        )
    )
    assert result is not None, "hover returned None"
    value = result.contents.value
    print("  mixed hover:", repr(value))
    assert "number = 1" in value, f"expected 'number = 1' in hover, got: {
        value}"
    assert "number = 2" in value, f"expected 'number = 2' in hover, got: {
        value}"
    assert 'name: string = "me"' in value, f"expected 'name: string = \"me\"' in hover, got: {
        value}"


@pytest.mark.asyncio(loop_scope="module")
async def test_import_hover_module_name(client: LanguageClient):
    """hover over `one` (the module name) should show module info with exports"""
    with tempfile.TemporaryDirectory() as tmpdir:
        _, two_uri = _open_import_pair(client, tmpdir)
        await client.wait_for_notification("textDocument/publishDiagnostics")

        result = await client.text_document_hover_async(
            params=HoverParams(
                position=Position(line=2, character=0),
                text_document=TextDocumentIdentifier(uri=two_uri),
            )
        )
        print("  module hover result:", result)
        assert result is not None, "hover on module name returned None"
        contents = result.contents
        assert contents is not None
        assert "module" in contents.value, f"expected 'module' in hover, got: {
            contents.value}"
        assert "fn hi(a: number, b: number) -> number" in contents.value, (
            f"expected fn signature in hover, got: {contents.value}"
        )
        assert contents.value.count("fn hi(") == 1, (
            f"expected no duplicate members, got: {contents.value}"
        )
        assert "const CT: int = 5" in contents.value, (
            f"expected const export in hover, got: {contents.value}"
        )


@pytest.mark.asyncio(loop_scope="module")
async def test_import_hover_autoopen(client: LanguageClient):
    """hover over imported fn when only the importer is opened"""
    with tempfile.TemporaryDirectory() as tmpdir:
        one_path = os.path.join(tmpdir, "one.rv")
        with open(one_path, "w") as f:
            f.write(ONE_RV_CONTENT)

        two_path = os.path.join(tmpdir, "two.rv")
        with open(two_path, "w") as f:
            f.write(TWO_RV_CONTENT)

        two_uri = "file://" + two_path
        client.text_document_did_open(params=DidOpenTextDocumentParams(
            text_document=TextDocumentItem(
                uri=two_uri, language_id="revo", version=1, text=TWO_RV_CONTENT),
        ))
        await client.wait_for_notification("textDocument/publishDiagnostics")

        result = await client.text_document_hover_async(
            params=HoverParams(
                position=Position(line=2, character=4),
                text_document=TextDocumentIdentifier(uri=two_uri),
            )
        )
        print("  autoopen hover result:", result)
        assert result is not None, "hover on imported fn (auto-open) returned None"
        contents = result.contents
        assert contents is not None
        assert "hi" in contents.value, f"expected 'hi' in hover, got: {
            contents.value}"
        assert "fn hi" in contents.value or "num" in contents.value, (
            f"expected fn signature in hover, got: {contents.value}"
        )
