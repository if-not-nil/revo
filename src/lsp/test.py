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
    InitializeParams,
    Position,
    ReferenceContext,
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
REVOPLS = str(REPO_ROOT / "zig-out" / "bin" / "revolt")


@pytest_lsp.fixture(
    scope="module",
    config=ClientServerConfig(server_command=[REVOPLS]),
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
DOC_TEXT = """@doc "greets a person by name"
fn greet(name: string) string do
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
    assert "**x**" in contents.value, "expected markdown with name"
    assert "binding" in contents.value, "expected kind"
    assert "int" in contents.value, "expected type"
    assert "let x = 42" in contents.value, "expected definition source"


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
    assert "fn" not in labels, f"'fn' should not match 'pri' prefix, got {labels}"
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
    assert kinds.get("fn") == 14, f"'fn' should be Keyword kind (14), got {kinds.get('fn')}"
    assert kinds.get("if") == 14
    # functions should be kind=3 (Function)
    assert kinds.get("print") == 3, f"'print' should be Function kind (3), got {kinds.get('print')}"
    assert kinds.get("len") == 3
    # all kinds should be valid ints
    assert all(isinstance(v, int) for v in kinds.values()), "all kinds should be ints"

    client.text_document_did_close(
        params=DidCloseTextDocumentParams(
            text_document=TextDocumentIdentifier(uri=COMPLETION_URI),
        )
    )


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


@pytest.mark.skip(reason="TODO")
@pytest.mark.asyncio(loop_scope="module")
async def test_rename(client: LanguageClient):
    """rename should update all references"""
    result = await client.text_document_rename_async(
        params=RenameParams(
            text_document=TextDocumentIdentifier(uri=TEST_URI),
            position=Position(line=2, character=3),
            new_name="greet",
        ),
    )
    assert result is not None


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
