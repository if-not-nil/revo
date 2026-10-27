//! formatter? i barely know her!
//!
//! clang-format with `ColumnLimit: 0`, more or less
//! ~ idempotent
//! ~ refuses anything that does not parse, and parses its own output
//! ~ doesnt change semantics
//!
//! one test per rule right here check it out pretty sick right
//!
//! !- THOSE ITEMS WHERE FOUND USING AI CODING AGENTS -!
//! !- BUT ALL THE CODE FOR THEM IS WRITEN BY ME(w0x7y) -!
//! what is left todo:
//!
//! bugs - Finished
//! [x] - a `do` on an aligned continuation line indents its body and `end` from
//!      the aligned column: `fn(a,\n           b) do` puts `end` under `b`,
//!      not under `let`
//! [x] - atoms hug `)`/`}` even when they arent a method: `if x == 1 :yes` ->
//!      `if (x == 1):yes`, `{1} :a` -> `{1}:a` (same meaning, reads as a call)
//! [x] - a mid-line block comment gets two spaces before it: `let x =  ## c ## 1`
//! [x] - unary after unary hugs: `- -1` -> `--1`
//! [x] - a blank line after a trailing operator drops the continuation: `1 +\n\n2`
//!      leaves `2` at column 0
//! [x] - "doesnt change semantics" is only "output parses"; compare the token
//!      streams of input and output, minus synth/dropped parens
//! [x] - `src_col` counts bytes, so tab-indented or non-ascii lines lose their
//!      alignment
//!
//! missing, next to clang-format
//! [] - `# fmt: off` / `# fmt: on` regions (`// clang-format off`)
//! [] - range formatting: lsp `textDocument/rangeFormatting`, cli `--lines` (`-lines`)
//! [] - lsp sends one whole-document edit, so the cursor and undo jump; send
//!      minimal edits from `revo.diff` (`-cursor`, replacements)
//! [] - align trailing comments on consecutive lines (`AlignTrailingComments`)
//! [] - `#comment` -> `# comment` (`SpacesInLineCommentPrefix`)
//! [x] - strip trailing whitespace inside multi-line comments
//! [] - brace padding is kept as typed: `{a = 1 }`, `{ }` (`Cpp11BracedListStyle`,
//!      `SpaceInEmptyBlock`)
//! [] - `/ < > |` keep any gap as operators too: `x <y`, `a/ b`, `a> 1` stay
//!      (clang always spaces binary operators); needs type vs expr context from the walk
//! [] - `if ((x)) 4` keeps both parens, only `do` conditions drop them
//!      (`RemoveParentheses: MultipleParentheses`)
//! [x] - a leading `.field` line gets no continuation level (`|>`, `and`, `:m(` do)
//! [] - code inside `#{ }` is never formatted, a block in there stays at column 0
//! [] - blank line between top-level definitions? (`SeparateDefinitionBlocks`)
//!
//! optimizations
//! [] - quadratic: 16k lines take 1.7s, 32k take 6.3s; `assignLevels` scans
//!      every floor for every line (twice), `has` scans `ends`/`drops`/`cuts`
//!      per token; sort floors and sweep, binary search the sets
//! [] - cli `fmt` parses, then `format` lexes + parses, then parses its output:
//!      3 parses per file; let `format` hand back the parse failure instead
//! [] - synth parens go in front and the whole item list gets sorted; insert
//!      them in place during the token loop
test "formatter" {
    const cases = [_]Case{
        // spacing
        .{ .name = "spacing", .src =
        \\setfps{60}
        \\let col = getcolor {0x101042FF}
        \\while winshcl {} == 0 do
        \\  begindraw {}
        \\end
        \\let x=1
        \\let y =f( 1,2 )
        \\let z={a=1,b = 2}
        \\let dot = - 1
        \\let delta = a - 1
        \\let neg = f(- 1) * - 2
        \\
        , .want =
        \\setfps {60}
        \\let col = getcolor {0x101042FF}
        \\while winshcl {} == 0 do
        \\  begindraw {}
        \\end
        \\let x = 1
        \\let y = f(1, 2)
        \\let z = {a = 1, b = 2}
        \\let dot = -1
        \\let delta = a - 1
        \\let neg = f(-1) * -2
        \\
        },
        .{
            .name = "spaced lparen isnt a call",
            .src = "let o = (if self.cur == cur ('> ') else '  ')\n",
            .want = "let o = (if (self.cur == cur) ('> ') else '  ')\n",
        },
        .{
            .name = "an atom only hugs as a method",
            .src = "let a = if x == 1 :yes else :no\nlet s = foo() :len()\n",
            .want = "let a = if (x == 1) :yes else :no\nlet s = foo():len()\n",
        },
        .{
            .name = "unary after unary",
            .src = "let a = - -1\nlet b = --1\nlet c = 2 - -1\n",
            .want = "let a = - -1\nlet b = - -1\nlet c = 2 - -1\n",
        },
        .{ .name = "spacing stays put", .src =
        \\let r = fs.open("x")?:read()
        \\pub declare f = fn(a: any) -> !any/:Fail
        \\let xs = make<number>(1)
        \\let n = self.tl[ch]
        \\let c = count()
        \\fn d(b) if (b == 0) {:err, 1} else {:ok, 2}
        \\fn p(x) -> Point {x = x}
        \\let a = { x = 1 }
        \\let b = {x = 2}
        \\type R = { token: string }
        \\pub declare json = {
        \\  encode: fn(value: any, ?pretty: bool) -> !string,
        \\}
        \\pub declare table = {
        \\  slice: fn(self: table, start: number, end: number) -> table,
        \\}
        \\
        },

        // indentation
        .{ .name = "blocks and brackets", .src =
        \\fn f(a) do
        \\if (a) do
        \\print(a)
        \\end
        \\end
        \\
        , .want =
        \\fn f(a) do
        \\  if a do
        \\    print(a)
        \\  end
        \\end
        \\
        },
        .{ .name = "nested tables", .src =
        \\let t={
        \\a=1,
        \\b={
        \\c=2,
        \\},
        \\}
        \\
        , .want =
        \\let t = {
        \\  a = 1,
        \\  b = {
        \\    c = 2,
        \\  },
        \\}
        \\
        },
        .{ .name = "arms align with `match`", .src =
        \\const m = match x
        \\| 1 => "one"
        \\| _ => "other"
        \\
        },
        .{ .name = "arms of a continued match", .src =
        \\const m =
        \\match x
        \\| 1 => "one"
        \\| _ => "other"
        \\
        , .want =
        \\const m =
        \\  match x
        \\  | 1 => "one"
        \\  | _ => "other"
        \\
        },
        .{ .name = "pipes get one level", .src =
        \\let v = x
        \\|> f
        \\|> g
        \\
        , .want =
        \\let v = x
        \\  |> f
        \\  |> g
        \\
        },
        .{ .name = "a block on a pipe line keeps its level", .src =
        \\let v = x
        \\|> bind(fn(c) do
        \\c * 2
        \\end)
        \\|> inspect
        \\
        , .want =
        \\let v = x
        \\  |> bind(fn(c) do
        \\    c * 2
        \\  end)
        \\  |> inspect
        \\
        },
        .{ .name = "a block ending a continued line indents from that line", .src =
        \\let v = x
        \\|> fn(c) do
        \\c * 2
        \\end
        \\|> inspect
        \\const f =
        \\fn() do
        \\1
        \\end
        \\for i in xs
        \\|> filter(p) do
        \\print(i)
        \\end
        \\
        , .want =
        \\let v = x
        \\  |> fn(c) do
        \\    c * 2
        \\  end
        \\  |> inspect
        \\const f =
        \\  fn() do
        \\    1
        \\  end
        \\for i in xs
        \\  |> filter(p) do
        \\  print(i)
        \\end
        \\
        },
        .{ .name = "method chains continue", .src =
        \\const w =
        \\fs.open(c)?:read()?
        \\:replace("a", "b")
        \\:split(" ")
        \\
        , .want =
        \\const w =
        \\  fs.open(c)?:read()?
        \\  :replace("a", "b")
        \\  :split(" ")
        \\
        },
        .{ .name = "field chains continue", .src =
        \\let n = self
        \\.tl
        \\.len
        \\
        , .want =
        \\let n = self
        \\  .tl
        \\  .len
        \\
        },
        .{ .name = "trailing operators continue, comments too", .src =
        \\let x = 1 +
        \\2 +
        \\3
        \\let y = 1 +
        \\# note
        \\2
        \\
        , .want =
        \\let x = 1 +
        \\  2 +
        \\  3
        \\let y = 1 +
        \\  # note
        \\  2
        \\
        },
        .{ .name = "leading closers dedent to their opener", .src =
        \\fn f() do
        \\f2(fn() do
        \\1
        \\end)
        \\end
        \\
        , .want =
        \\fn f() do
        \\  f2(fn() do
        \\    1
        \\  end)
        \\end
        \\
        },
        .{ .name = "comments keep their place", .src =
        \\let x=1 # trailing
        \\# leading
        \\let y=2
        \\
        , .want =
        \\let x = 1  # trailing
        \\# leading
        \\let y = 2
        \\
        },
        .{ .name = "mid-line comments get one space", .src =
        \\let x = ## c ## 1
        \\let y = 2 ## c ##
        \\
        , .want =
        \\let x = ## c ## 1
        \\let y = 2  ## c ##
        \\
        },
        .{ .name = "comments stay in the body", .src =
        \\fn f() do
        \\# body comment
        \\print(1)
        \\# before end
        \\end
        \\
        , .want =
        \\fn f() do
        \\  # body comment
        \\  print(1)
        \\  # before end
        \\end
        \\
        },
        .{ .name = "multi-line comments move as a whole", .src =
        \\fn f() do
        \\if (a) do
        \\## line one
        \\
        \\   line two ##
        \\print(1)
        \\end
        \\end
        \\    #* doc one
        \\     * doc two *#
        \\fn g() 1
        \\
        , .want =
        \\fn f() do
        \\  if a do
        \\    ## line one
        \\
        \\       line two ##
        \\    print(1)
        \\  end
        \\end
        \\#* doc one
        \\ * doc two *#
        \\fn g() 1
        \\
        },
        .{
            .name = "comments lose trailing whitespace",
            .src = "let x = 1 # c \t\n## a  \n  \t\n  b \n##\n#* d  \r\n *#\nfn g() 1\n",
            .want = "let x = 1  # c\n## a\n\n  b\n##\n#* d\n *#\nfn g() 1\n",
        },
        .{ .name = "continuations keep their alignment", .src =
        \\let t = {a = 1,
        \\         b = 2}
        \\fn f() do
        \\  loop g(x)
        \\       |> h
        \\end
        \\
        },
        .{ .name = "a do after an aligned line hangs off the opener", .src =
        \\let g = fn(a,
        \\           b) do
        \\  return a + b
        \\end
        \\fn f() do
        \\  run(fn(a,
        \\         b) do
        \\    return a
        \\  end)
        \\end
        \\
        },
        .{ .name = "alignment counts display columns", .src =
        \\let t = {a = "é", c = 1,
        \\                  b = 2}
        \\let u = {a = "日", c = 1,
        \\                   b = 2}
        \\
        },
        .{
            .name = "a tab-indented line keeps its alignment",
            .src = "fn f() do\n\tlet t = {a = 1,\n           b = 2}\nend\n",
            .want = "fn f() do\n  let t = {a = 1,\n           b = 2}\nend\n",
        },

        // boolean continuations
        .{ .name = "and/or get one level, leading or trailing", .src =
        \\fn f() do
        \\if a
        \\and b
        \\or c do
        \\d
        \\end
        \\if a and
        \\b do
        \\c
        \\end
        \\end
        \\
        , .want =
        \\fn f() do
        \\  if a
        \\    and b
        \\    or c do
        \\    d
        \\  end
        \\  if a and
        \\    b do
        \\    c
        \\  end
        \\end
        \\
        },

        // blank lines
        .{ .name = "blank runs are capped at two", .src =
        \\let a = 1
        \\
        \\
        \\
        \\
        \\let b = 2
        \\
        \\let c = 3
        \\
        \\
        \\let d = 4
        \\
        , .want =
        \\let a = 1
        \\
        \\
        \\let b = 2
        \\
        \\let c = 3
        \\
        \\
        \\let d = 4
        \\
        },
        .{ .name = "no blank after an opener or before a closer", .src =
        \\fn f() do
        \\
        \\
        \\x
        \\
        \\
        \\end
        \\
        , .want =
        \\fn f() do
        \\  x
        \\end
        \\
        },
        .{ .name = "a blank line keeps the continuation", .src =
        \\let b = 1 +
        \\
        \\2
        \\let c = 1 and
        \\
        \\ 2
        \\
        , .want =
        \\let b = 1 +
        \\
        \\  2
        \\let c = 1 and
        \\
        \\  2
        \\
        },

        // structure
        .{ .name = "if and unless take parens, do drops them", .src =
        \\if 1 > 2 4
        \\unless x 1
        \\if ((x)) do
        \\4
        \\end
        \\if x
        \\4
        \\
        , .want =
        \\if (1 > 2) 4
        \\unless (x) 1
        \\if x do
        \\  4
        \\end
        \\if (x)
        \\  4
        \\
        },
        .{ .name = "while takes parens, do drops them", .src =
        \\while i < 10 i += 1
        \\while (i < 10) do
        \\i += 1
        \\end
        \\
        , .want =
        \\while (i < 10) i += 1
        \\while i < 10 do
        \\  i += 1
        \\end
        \\
        },
        .{ .name = "do-less bodies indent from their construct", .src =
        \\const r = loop/l do
        \\if (:true)
        \\break/l 42
        \\end
        \\
        , .want =
        \\const r = loop/l do
        \\  if (:true)
        \\    break/l 42
        \\end
        \\
        },
        .{ .name = "do-less if and else", .src =
        \\if (:false)
        \\print("then")
        \\else
        \\print("else")
        \\
        , .want =
        \\if (:false)
        \\  print("then")
        \\else
        \\  print("else")
        \\
        },
        .{ .name = "else if chains stay flat", .src =
        \\if (a)
        \\1
        \\else if (b)
        \\2
        \\else if (c)
        \\3
        \\else 4
        \\
        , .want =
        \\if (a)
        \\  1
        \\else if (b)
        \\  2
        \\else if (c)
        \\  3
        \\else 4
        \\
        },
        .{ .name = "an if on the line after else still indents", .src =
        \\if (a) 1
        \\else
        \\if (b) 2
        \\else 3
        \\
        , .want =
        \\if (a) 1
        \\else
        \\  if (b) 2
        \\  else 3
        \\
        },
        .{ .name = "do-less while and for", .src =
        \\let n = 0
        \\while (n < 2)
        \\n = n + 1
        \\for i in 0..3
        \\print(i)
        \\
        , .want =
        \\let n = 0
        \\while (n < 2)
        \\  n = n + 1
        \\for i in 0..3
        \\  print(i)
        \\
        },
        .{ .name = "a body on its own line gets a level", .src =
        \\for i in 0..3
        \\f(i)
        \\|> g
        \\
        , .want =
        \\for i in 0..3
        \\  f(i)
        \\    |> g
        \\
        },
        .{ .name = "an unaligned continuation gets one level", .src =
        \\loop parse_json(input()?)
        \\|> print("x")
        \\
        , .want =
        \\loop parse_json(input()?)
        \\  |> print("x")
        \\
        },
        .{ .name = "continued do-less bodies", .src =
        \\fn f() do
        \\const direction =
        \\if (context.argv:len() > 1)
        \\context.argv[1]
        \\else ""
        \\end
        \\
        , .want =
        \\fn f() do
        \\  const direction =
        \\    if (context.argv:len() > 1)
        \\      context.argv[1]
        \\    else ""
        \\end
        \\
        },
        .{ .name = "glued statements split", .src =
        \\print("the basics") const n = 42 const f = 3.14 print(n, f)
        \\
        , .want =
        \\print("the basics")
        \\const n = 42
        \\const f = 3.14
        \\print(n, f)
        \\
        },
        .{ .name = "a split block ends on its own line", .src =
        \\fn f() do a b end
        \\
        , .want =
        \\fn f() do
        \\  a
        \\  b
        \\end
        \\
        },
        .{ .name = "semicolons keep their line", .src =
        \\let a = {inner = 21, mutate = fn(self) do self.inner *= 2; self end}
        \\
        },

        // nothing else moves
        .{ .name = "declarations stay put", .src =
        \\const a = 1
        \\const bbb = 2
        \\let x = 3
        \\let yyyy = 4
        \\fn f() 1
        \\fn g() 2
        \\const c = 3
        \\
        },
        .{ .name = "strings and docs stay as-is", .src =
        \\#! a
        \\b
        \\!#
        \\
        \\#* d *#
        \\const s = "a  b #{ x }"
        \\let x=1
        \\
        , .want =
        \\#! a
        \\b
        \\!#
        \\
        \\#* d *#
        \\const s = "a  b #{ x }"
        \\let x = 1
        \\
        },

        // rejects
        .{ .name = "stray paren", .src = ")\n", .reject = true },
        .{ .name = "stray brace", .src = "}\n", .reject = true },
    };
    for (cases) |c| {
        check(c) catch |err| {
            std.debug.print("case `{s}`\n", .{c.name});
            return err;
        };
    }
}

test "output with other tokens or comments is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "# keep\nlet w = f (1)\nif (x) do\n  g()\nend\nif y 4\n";
    const lexed = try Lexer.lexAll(arena, src);
    var walk: Walk = .{ .alloc = arena, .source = src };
    walk.visit((try parse(arena, src)).ok);

    try testing.expect(try sameTokens(arena, lexed, &walk, "# keep\nlet w = f\n(1)\nif x do\n  g()\nend\nif (y) 4\n"));
    // `f (1)` isnt a call, `f(1)` is
    try testing.expect(!try sameTokens(arena, lexed, &walk, "# keep\nlet w = f(1)\nif x do\n  g()\nend\nif (y) 4\n"));
    try testing.expect(!try sameTokens(arena, lexed, &walk, "# keep\nlet w = f\n(1)\nif x do\nend\nif (y) 4\n"));
    try testing.expect(!try sameTokens(arena, lexed, &walk, "# keep\nlet w = f\n(1)\nif x do\n  g()\nend\nif y 4\n"));
    // a lost or edited comment
    try testing.expect(!try sameTokens(arena, lexed, &walk, "let w = f\n(1)\nif x do\n  g()\nend\nif (y) 4\n"));
    try testing.expect(!try sameTokens(arena, lexed, &walk, "# kept\nlet w = f\n(1)\nif x do\n  g()\nend\nif (y) 4\n"));
}

const std = @import("std");

const cst = @import("cst.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const diagnostic = @import("diagnostic.zig");

const TokenType = Lexer.TokenType;

pub const indent_unit = "  ";

const indent_cols: u32 = indent_unit.len;

/// longest run of blank lines to keep
const max_blanks: u32 = 2;

/// stripped from the end of every comment line
const trailing_space = " \t\r";

pub const FormatError = error{ OutOfMemory, InvalidSource, FormatterBug };

// -- [test helpers] ----------------------------------------------------------

const testing = std.testing;

const Case = struct {
    name: []const u8,
    src: []const u8,
    /// expected output
    /// null means the source is already formatted
    want: ?[]const u8 = null,
    reject: bool = false,
};

fn check(c: Case) !void {
    if (c.reject) {
        try testing.expectError(error.InvalidSource, format(testing.allocator, c.src));
        return;
    }
    const want = c.want orelse c.src;
    const got = try format(testing.allocator, c.src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);

    // a second pass changes nothing
    const again = try format(testing.allocator, got);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(want, again);
}

// -- [types] -----------------------------------------------------------------

/// strings swallow their whole modal form
const Item = struct {
    text: []const u8,
    kind: TokenType,
    line: u32,
    start: usize,
    /// display column in the source, to infer alignment
    src_col: u32 = 0,
    space_before: bool = false,
    trivia: bool = false,
    /// a paren the formatter adds
    synth: bool = false,
};

/// items from one source line, plus the indent and blank lines it gets
const Line = struct {
    items: []const Item,
    /// indent in spaces
    col: u32 = 0,
    /// blank lines before this one, at most `max_blanks`
    blanks: u8 = 0,
    /// offset of the first code item at or after this line
    /// , so a comment line is placed like the code it precedes
    lo: usize = 0,
};

/// lines starting in `[start, end)` sit at least `indent` columns in
///   from the line that has `anchor`
/// - a `do`-less body: `indent` is one level
/// - a `match` arm or an `else`: `indent` is zero, they line up with the
///   keyword that owns them
const Floor = struct {
    anchor: usize,
    start: usize,
    end: usize,
    indent: u32,
    /// set once the anchor's line is placed
    col: ?u32 = null,
};

/// an open `do` or bracket
const Open = struct {
    /// column its body is at
    col: u32,
    line: usize = 0,
    /// first item after a bracket whose line carries on: later lines can
    /// align under an item fromhereon
    from: ?usize = null,
};

/// the line a statement starts on, for the continuation lines that follow
const Head = struct {
    /// bracket/block depth the line starts at
    depth: usize,
    col: u32,
    line: usize,
    /// first item a continuation may align under
    from: usize,
};

/// parens to add around an `if` condition: `if (1 > 2) 4`
const Parens = struct {
    open_at: usize,
    /// just past the condition's last token
    close_at: usize,
    open_line: u32,
    close_line: u32,
};

// -- [entry] -----------------------------------------------------------------

/// format `source`, caller owns the result
/// `InvalidSource` on anything the parser wont take, `FormatterBug` when the
/// output wouldnt parse or would mean something else
pub fn format(allocator: std.mem.Allocator, source: []const u8) FormatError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lexed = try Lexer.lexAll(arena, source);
    if (lexed.errors.len > 0) return error.InvalidSource;

    const root = switch (try parse(arena, source)) {
        .ok => |r| r,
        .err => return error.InvalidSource,
    };
    var walk: Walk = .{ .alloc = arena, .source = source };
    walk.visit(root);
    if (walk.failed) return error.OutOfMemory;

    const items = try collectItems(arena, source, lexed, &walk);
    const lines = try splitLines(arena, items, walk.cuts.items);
    trimBlanks(lines);
    try assignLevels(arena, lines, walk.floors.items, walk.cond_dos.items);
    const out = try emit(allocator, lines);
    errdefer allocator.free(out);

    // sometimes you NEED whitespace (`:method(`)
    // , so never hand back something the parser wouldnt take
    switch (try parse(arena, out)) {
        .ok => {},
        .err => return error.FormatterBug,
    }
    // parsing alone misses `f (1)` -> `f(1)`, which parses but now calls `f`
    if (!try sameTokens(arena, lexed, &walk, out)) return error.FormatterBug;
    return out;
}

fn parse(arena: std.mem.Allocator, source: []const u8) FormatError!Parser.ParseResult {
    return Parser.parseSourceReport(arena, source, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSource,
    };
}

/// `out` lexes to the source's tokens and comments, minus the dropped parens
/// and plus the synthetic ones, and keeps every gap that picks a call over a
/// grouping
fn sameTokens(arena: std.mem.Allocator, lexed: Lexer.LexOutput, w: *const Walk, out: []const u8) FormatError!bool {
    const relexed = try Lexer.lexAll(arena, out);
    const got = relexed.tokens;

    // a comment changes nothing at runtime, but losing one loses the user's text
    if (relexed.trivia.len != lexed.trivia.len) return false;
    for (relexed.trivia, lexed.trivia) |g, x| {
        if (g.type != x.type or !sameText(g.type, g.text, x.text)) return false;
    }

    const open: Lexer.Token = .{ .type = .lparen, .text = "(", .line = 0, .column = 0, .start = 0, .end = 0, .space_before = true };
    const close: Lexer.Token = .{ .type = .rparen, .text = ")", .line = 0, .column = 0, .start = 0, .end = 0 };
    var want: std.ArrayList(Lexer.Token) = .empty;
    for (lexed.tokens) |tok| {
        for (w.parens.items) |p| if (p.open_at == tok.start) try want.append(arena, open);
        if (!has(w.drops.items, tok.start)) try want.append(arena, tok);
        for (w.parens.items) |p| if (p.close_at == tok.end) try want.append(arena, close);
    }
    if (got.len != want.items.len) return false;

    for (got, want.items, 0..) |g, x, i| {
        if (g.type != x.type or !sameText(g.type, g.text, x.text)) return false;
        // `f(x)` and `f<T>(x)` call, `f (x)` and `a < b` dont; after a
        // keyword or a dropped paren the gap means nothing
        const prev = if (i > 0) want.items[i - 1].type else continue;
        const after_expr = endsExpr(prev) or oneOf(prev, &.{ .string_end, .ml_string_end });
        if (oneOf(g.type, &.{ .lparen, .lt }) and after_expr and g.space_before != x.space_before) return false;
    }
    return true;
}

/// a comment's later lines move with the code and lose trailing whitespace,
/// see `appendShifted`
fn sameText(kind: TokenType, a: []const u8, b: []const u8) bool {
    if (!oneOf(kind, &.{ .comment, .doc_comment, .module_doc })) return std.mem.eql(u8, a, b);
    var rows_a = std.mem.splitScalar(u8, a, '\n');
    var rows_b = std.mem.splitScalar(u8, b, '\n');
    while (rows_a.next()) |row| {
        const other = rows_b.next() orelse return false;
        const x = std.mem.trimEnd(u8, std.mem.trimStart(u8, row, " "), trailing_space);
        const y = std.mem.trimEnd(u8, std.mem.trimStart(u8, other, " "), trailing_space);
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return rows_b.next() == null;
}

// -- [structure] -------------------------------------------------------------

/// one walk over the tree collects everything the line passes need
const Walk = struct {
    alloc: std.mem.Allocator,
    /// source text, for counting newlines in a wrapped condition
    source: []const u8,
    /// set on oom; stops the walk
    failed: bool = false,
    floors: std.ArrayList(Floor) = .empty,
    /// offsets of the `end`s that close a `do` block; any other `end` is a name
    ends: std.ArrayList(usize) = .empty,
    /// offsets that start a new line: statements glued onto one source line
    cuts: std.ArrayList(usize) = .empty,
    /// `if`/`unless`/`while` conditions to wrap
    parens: std.ArrayList(Parens) = .empty,
    /// paren tokens to drop around a `do`-block condition
    drops: std.ArrayList(usize) = .empty,
    /// offsets of the `do`s that end an `if`/`while`/`for` condition
    cond_dos: std.ArrayList(usize) = .empty,

    /// append and flag oom so the walk stops
    fn push(self: *Walk, list: anytype, item: std.meta.Child(@TypeOf(list.items))) void {
        list.append(self.alloc, item) catch {
            self.failed = true;
        };
    }

    pub fn visit(self: *Walk, node: *const cst.CstNode) void {
        if (self.failed) return;

        if (cst.blockStmts(node)) |stmts| {
            const end_tok: ?Lexer.Token = switch (node.kind) {
                .do_block => |d| d.end_tok,
                else => null,
            };
            if (end_tok) |end| self.push(&self.ends, end.start);

            // 2+ statements glued onto one source line each start a line,
            // and a split block's `end` gets one too
            var i: usize = 0;
            while (i < stmts.len) {
                var j = i + 1;
                while (j < stmts.len and stmts[j].span.line == stmts[i].span.line) j += 1;
                if (j - i >= 2) {
                    for (stmts[i..j]) |s| self.push(&self.cuts, s.span.start);
                    if (end_tok) |end| {
                        if (end.line == stmts[i].span.line) self.push(&self.cuts, end.start);
                    }
                }
                i = j;
            }
        }

        const at = node.span.start;
        switch (node.kind) {
            .if_expr => |i| {
                self.body(at, i.then);
                if (i.else_tok) |t| {
                    // the else branch hangs off the `else` line; an `else if` chains flat
                    if (i.else_) |e| if (e.kind != .if_expr or e.span.line != t.line) self.body(t.start, e);
                    self.pin(at, t.start);
                }
                self.condParens(i.cond, i.then);
                self.condDo(i.then);
            },
            .while_loop => |w| {
                self.body(at, w.body);
                self.condParens(w.pred, w.body);
                self.condDo(w.body);
            },
            .for_loop => |f| {
                self.body(at, f.body);
                self.condDo(f.body);
            },
            .loop_expr => |l| self.body(at, l.body),
            .fn_def => |f| self.body(at, f.body),
            .fn_method => |f| self.body(at, f.body),
            // arms line up with the `match` keyword itself
            .match => |m| for (m.bars) |bar| self.pin(at, bar.start),
            else => {},
        }

        cst.walkCst(Walk, self, node);
    }

    /// a body that isnt a `do` block indents one level
    fn body(self: *Walk, anchor: usize, node: *const cst.CstNode) void {
        if (node.kind == .do_block or node.span.end <= node.span.start) return;
        self.push(&self.floors, .{
            .anchor = anchor,
            .start = node.span.start,
            .end = node.span.end,
            .indent = indent_cols,
        });
    }

    /// the line starting at `offset` lines up with the line holding `anchor`
    fn pin(self: *Walk, anchor: usize, offset: usize) void {
        self.push(&self.floors, .{ .anchor = anchor, .start = offset, .end = offset + 1, .indent = 0 });
    }

    fn condDo(self: *Walk, body_node: *const cst.CstNode) void {
        if (body_node.kind == .do_block) self.push(&self.cond_dos, body_node.kind.do_block.do_tok.start);
    }

    /// `if (cond) 4` wraps, `if cond do` unwraps: parens delimit an
    /// inline body, a `do` block already does
    fn condParens(self: *Walk, cond: *const cst.CstNode, body_node: *const cst.CstNode) void {
        if (body_node.kind == .do_block) {
            var cur = cond;
            while (cur.kind == .paren) {
                const p = cur.kind.paren;
                const inner = p.expr orelse return;
                self.push(&self.drops, p.lparen_tok.start);
                self.push(&self.drops, p.rparen_tok.start);
                cur = inner;
            }
        } else if (cond.kind != .paren) {
            self.push(&self.parens, .{
                .open_at = cond.span.start,
                .close_at = cond.span.end,
                .open_line = cond.span.line,
                .close_line = self.endLine(cond.span),
            });
        }
    }

    fn endLine(self: *Walk, span: Lexer.Span) u32 {
        if (span.end <= span.start or span.end > self.source.len) return span.line;
        return span.line + @as(u32, @intCast(std.mem.count(u8, self.source[span.start..span.end], "\n")));
    }
};

fn has(set: []const usize, x: usize) bool {
    return std.mem.indexOfScalar(usize, set, x) != null;
}

// -- [items] -----------------------------------------------------------------

/// code tokens + their leading comments + absorbed strings, in source order;
/// wraps conditions that need parens and drops the parens a `do` block makes
/// redundant
fn collectItems(arena: std.mem.Allocator, source: []const u8, lexed: Lexer.LexOutput, w: *const Walk) ![]Item {
    var items: std.ArrayList(Item) = .empty;

    // synthetic parens go in first and are sorted into place at the end
    for (w.parens.items) |p| {
        try items.append(arena, .{ .text = "(", .kind = .lparen, .line = p.open_line, .start = p.open_at, .space_before = true, .synth = true });
        try items.append(arena, .{ .text = ")", .kind = .rparen, .line = p.close_line, .start = p.close_at, .synth = true });
    }

    var i: usize = 0;
    while (i < lexed.tokens.len) {
        const tok = lexed.tokens[i];
        for (lexed.leadingTrivia(tok)) |c| try items.append(arena, .{
            .text = source[c.start..c.end],
            .kind = c.type,
            .line = c.line,
            .start = c.start,
            .src_col = srcCol(source, c.start),
            .trivia = true,
        });
        if (tok.type == .eof) break;
        i += 1;
        if (has(w.drops.items, tok.start)) continue;

        // a whole `"..."`/`"""..."""` is one item, interp code included
        var end = tok.end;
        var kind = tok.type;
        if (kind == .string_start or kind == .ml_string_start) {
            var depth: usize = 1;
            while (i < lexed.tokens.len and depth > 0) : (i += 1) switch (lexed.tokens[i].type) {
                .string_start, .ml_string_start => depth += 1,
                .string_end, .ml_string_end => depth -= 1,
                else => {},
            };
            end = lexed.tokens[i - 1].end;
            kind = .string;
        }

        // `end` doubles as a plain name (`fn(..., end: number)`, `{end = 1}`);
        // only the ones that close a `do` block stay closers
        if (kind == .kw_end and !has(w.ends.items, tok.start)) kind = .ident;

        try items.append(arena, .{
            .text = source[tok.start..end],
            .kind = kind,
            .line = tok.line,
            .start = tok.start,
            .src_col = srcCol(source, tok.start),
            .space_before = tok.space_before,
        });
    }
    // stable, so a synthetic paren lands before the token it sits on
    std.mem.sort(Item, items.items, {}, lessItem);
    return items.items;
}

fn lessItem(_: void, a: Item, b: Item) bool {
    return a.start < b.start or (a.start == b.start and a.synth and !b.synth);
}

/// display column, not bytes: `é` is 1 wide, `日` 2, a tab snaps to `diagnostic`'s stops
fn srcCol(source: []const u8, at: usize) u32 {
    const nl = std.mem.lastIndexOfScalar(u8, source[0..at], '\n');
    return @intCast(diagnostic.displayWidth(source[if (nl) |n| n + 1 else 0..at], 0));
}

// -- [lines] -----------------------------------------------------------------

/// group items by original line, stamping blank-line gaps; glued
/// statements then split onto their own lines
fn splitLines(arena: std.mem.Allocator, items: []const Item, cuts: []const usize) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    var end_line: u32 = 0;
    var blanks: u8 = 0;

    for (items, 0..) |it, idx| {
        if (idx > 0 and it.line > end_line) {
            try appendSourceLine(arena, items[start..idx], blanks, cuts, &lines);
            blanks = @intCast(@min(it.line - end_line - 1, max_blanks));
            start = idx;
        }
        end_line = it.line + @as(u32, @intCast(std.mem.count(u8, it.text, "\n")));
    }
    if (items.len > start) try appendSourceLine(arena, items[start..], blanks, cuts, &lines);

    // comment lines borrow the position of the code after them
    const out = lines.items;
    var next_code: ?usize = null;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        if (firstCodeItem(out[i].items)) |it| next_code = it.start;
        out[i].lo = next_code orelse out[i].items[0].start;
    }
    return out;
}

fn appendSourceLine(
    arena: std.mem.Allocator,
    group: []const Item,
    blank: u8,
    cuts: []const usize,
    lines: *std.ArrayList(Line),
) !void {
    // `;`-separated statements keep their line, per the house style
    const semi = for (group) |it| {
        if (!it.trivia and it.kind == .semicolon) break true;
    } else false;

    // statements the walk marked as glued get their own line
    var first: usize = 0;
    if (!semi) for (group, 0..) |it, idx| {
        if (it.trivia or idx == first or !has(cuts, it.start)) continue;
        try lines.append(arena, .{ .items = group[first..idx], .blanks = if (first == 0) blank else 0 });
        first = idx;
    };
    try lines.append(arena, .{ .items = group[first..], .blanks = if (first == 0) blank else 0 });
}

/// no blank line right after an opener or right before a closer
fn trimBlanks(lines: []Line) void {
    var prev_last: ?TokenType = null;
    for (lines) |*line| {
        if (line.blanks != 0) {
            const after_opener = if (prev_last) |k| isOpener(k) else false;
            const before_closer = if (firstCodeItem(line.items)) |it| isCloser(it.kind) else false;
            if (after_opener or before_closer) line.blanks = 0;
        }
        if (lastCodeItem(line.items)) |it| prev_last = it.kind;
    }
}

// -- [levels] ----------------------------------------------------------------

/// indent from `do`/`end` + bracket nesting and `do`-less bodies / match arms / `else` (floors)
///
/// a line that was aligned under a token of its statements head line, or
/// under an item after an open bracket that went on, stays under that token
fn assignLevels(arena: std.mem.Allocator, lines: []Line, floors: []Floor, cond_dos: []const usize) FormatError!void {
    var stack: std.ArrayList(Open) = .empty;
    var heads: std.ArrayList(Head) = .empty;
    var prev_kind: ?TokenType = null;

    for (lines, 0..) |*line, li| {
        const slice = line.items;
        const depth = stack.items.len;
        const first_idx = firstCodeIndex(slice);

        // how does the line opens
        const leads = if (first_idx) |fi| switch (slice[fi].kind) {
            .pipe_forward, .kw_and, .kw_or, .kw_orelse, .dot => true,
            // a bare `:atom` is its own statement, `:m(` continues
            .atom => if (firstCodeIndex(slice[fi + 1 ..])) |n|
                slice[fi + 1 + n].kind == .lparen and !slice[fi + 1 + n].space_before
            else
                false,
            else => false,
        } else false;
        const tail = if (prev_kind) |k| isContinuationTail(k) else false;
        const continued = leads or tail;

        // the statement this line belongs to, if it is a continuation
        while (heads.items.len > 0 and heads.items[heads.items.len - 1].depth > depth) _ = heads.pop();
        const head: ?Head = if (heads.items.len > 0 and heads.items[heads.items.len - 1].depth == depth)
            heads.items[heads.items.len - 1]
        else
            null;

        var col: u32 = if (depth > 0) stack.items[depth - 1].col else 0;
        for (floors) |f| {
            if (f.col) |fc| {
                if (line.lo >= f.start and line.lo < f.end) col = @max(col, fc);
            }
        }
        const base_col = col;
        const stmt_col = if (head) |h| h.col else base_col;
        if (continued) col = @max(col, stmt_col + indent_cols);

        // keep an alignment the source had
        if (first_idx) |fi| {
            const f = slice[fi];
            if (!f.synth and !isCloser(f.kind)) {
                var aligned: ?u32 = null;
                if (continued and head != null) aligned = inferCol(lines[head.?.line], head.?.from, f.src_col);
                if (aligned == null and depth > 0) {
                    const o = stack.items[depth - 1];
                    if (o.from) |from| aligned = inferCol(lines[o.line], from, f.src_col);
                }
                if (aligned) |a| col = @max(base_col, a);
            }
        }

        var leading = true;
        // where an opener hangs from: this line, or the line that opened the
        // last thing closed on it (`fn(a,\n     b) do` hangs off the `fn(` line)
        var hang = col;
        for (slice, 0..) |it, idx| {
            if (it.trivia) continue;

            if (isCloser(it.kind)) {
                // the parser guarantees balance
                const o = stack.pop() orelse continue;
                hang = o.col - indent_cols;
                if (leading) col = hang;
                leading = false;
                continue;
            }

            if (isOpener(it.kind)) {
                // a `do` that ends a wrapped condition hangs its body off the
                // statement; any other `do` (`|> fn(c) do`) hangs off its own line
                const from = if (continued and stack.items.len <= depth and has(cond_dos, it.start)) stmt_col else hang;
                const goes_on = it.kind != .kw_do and firstCodeIndex(slice[idx + 1 ..]) != null;
                try stack.append(arena, .{
                    .col = from + indent_cols,
                    .line = li,
                    .from = if (goes_on) idx + 1 else null,
                });
            }
            leading = false;
        }

        line.col = col;
        if (lastCodeItem(slice)) |it| prev_kind = it.kind;

        if (first_idx != null and !continued) {
            while (heads.items.len > 0 and heads.items[heads.items.len - 1].depth >= depth) _ = heads.pop();
            try heads.append(arena, .{ .depth = depth, .col = col, .line = li, .from = first_idx.? + 1 });
        }

        // place the floors anchored on this line
        const last = slice[slice.len - 1];
        const hi = last.start + last.text.len;
        for (floors) |*f| {
            if (f.col == null and f.anchor >= line.lo and f.anchor < hi) f.col = col + f.indent;
        }
    }
}

/// where `anchor` prints the item from `from` on that sat at source column
/// `src_col`; null if none did or the line is too odd to measure
fn inferCol(anchor: Line, from: usize, src_col: u32) ?u32 {
    var col = anchor.col;
    var prev: ?Item = null;
    var prev2: ?Item = null;

    for (anchor.items, 0..) |it, i| {
        if (std.mem.indexOfScalar(u8, it.text, '\n') != null) return null;
        if (prev) |p| col += @intCast(separator(prev2, p, it, nextItem(anchor.items, i)).len);
        if (i >= from and !it.trivia and !it.synth and it.src_col == src_col) return col;

        col += @intCast(diagnostic.displayWidth(it.text, col));
        prev2 = prev;
        prev = it;
    }
    return null;
}

fn firstCodeIndex(items: []const Item) ?usize {
    for (items, 0..) |it, i| {
        if (!it.trivia) return i;
    }
    return null;
}

fn firstCodeItem(items: []const Item) ?Item {
    return if (firstCodeIndex(items)) |i| items[i] else null;
}

fn nextItem(items: []const Item, i: usize) ?Item {
    return if (i + 1 < items.len) items[i + 1] else null;
}

fn lastCodeItem(items: []const Item) ?Item {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (!items[i].trivia) return items[i];
    }
    return null;
}

// -- [emit] ------------------------------------------------------------------

fn emit(allocator: std.mem.Allocator, lines: []const Line) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (lines) |line| {
        if (out.items.len > 0) try out.appendNTimes(allocator, '\n', @intCast(line.blanks));
        try out.appendNTimes(allocator, ' ', @intCast(line.col));

        var prev: ?Item = null;
        var prev2: ?Item = null;
        for (line.items, 0..) |it, i| {
            if (prev) |p| try out.appendSlice(allocator, separator(prev2, p, it, nextItem(line.items, i)));
            if (it.trivia or it.kind == .doc_comment) {
                // a multi-line comment keeps its shape: later lines move as far as the first did
                const delta = @as(i64, srcCol(out.items, out.items.len)) - it.src_col;
                try appendShifted(allocator, &out, it.text, delta);
            } else try out.appendSlice(allocator, it.text);
            prev2 = prev;
            prev = it;
        }
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

/// `text` with every line after the first moved `delta` columns, never past column 0,
/// and no line ending in whitespace
fn appendShifted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, delta: i64) !void {
    var rows = std.mem.splitScalar(u8, text, '\n');
    try out.appendSlice(allocator, std.mem.trimEnd(u8, rows.first(), trailing_space));
    while (rows.next()) |full| {
        try out.append(allocator, '\n');
        const row = std.mem.trimEnd(u8, full, trailing_space);
        // shortcut: only leading spaces move, a tab-indented comment line keeps its tabs
        const rest = std.mem.trimStart(u8, row, " ");
        if (rest.len == 0) continue;
        const pad = @max(0, @as(i64, @intCast(row.len - rest.len)) + delta);
        try out.appendNTimes(allocator, ' ', @intCast(pad));
        try out.appendSlice(allocator, rest);
    }
}

// -- [spacing] ---------------------------------------------------------------

fn oneOf(k: TokenType, comptime set: []const TokenType) bool {
    inline for (set) |s| {
        if (k == s) return true;
    }
    return false;
}

/// what goes between `p` and `c`; `prev2` tells unary from binary,
/// `next` is the item after `c` on its line
fn separator(prev2: ?Item, p: Item, c: Item, next: ?Item) []const u8 {
    // trailing comments get two spaces, per the house style; a `## ##` with
    // code after it gets one
    if (c.trivia) return if (next == null) "  " else " ";
    const gap: []const u8 = if (c.space_before) " " else "";

    // unary `-`/`+` hug their operand, but not another sign (`- -1`, not `--1`)
    if (oneOf(p.kind, &.{ .minus, .plus }) and !oneOf(c.kind, &.{ .minus, .plus }) and
        (prev2 == null or !endsExpr(prev2.?.kind))) return "";
    // `f(x)` is a call, `f (x)` is not (also `f<T>(x)`)
    if (c.kind == .lparen) return gap;
    // `?` hugs a postfix target (`x?:read()`) but spaces in prefix
    // positions (`, ?opts`, `a: ?number`)
    if (c.kind == .huh) return if (oneOf(p.kind, &.{ .lparen, .lbracket, .lsquiggly }) or endsExpr(p.kind)) "" else " ";
    // braces keep their padding (`{a = 1}`, `{ token: string }`), and
    // `/ < > |` keep their gaps: tight in types (`!any/:Fail`, `make<number>`,
    // `number|:nil`), spaced as operators
    if (oneOf(p.kind, &.{ .lsquiggly, .slash, .lt, .gt, .bar }) or
        oneOf(c.kind, &.{ .rsquiggly, .slash, .lt, .gt, .bar })) return gap;

    if (oneOf(c.kind, &.{ .comma, .semicolon, .rparen, .rbracket, .dot, .dotdot, .colon })) return "";
    if (oneOf(p.kind, &.{ .lparen, .lbracket, .dot, .dotdot, .huh, .bang })) return "";
    // `f[0]` hugs, `if (` doesnt: a call target is anything that can end an
    // expression, plus the `fn` keyword, but not `end`
    if (c.kind == .lbracket and (p.kind == .kw_fn or (p.kind != .kw_end and endsExpr(p.kind)))) return "";
    // `x:method()`; an atom is only a method when a `(` hugs it, so
    // `if (x == 1) :yes` keeps its space
    const method = if (next) |n| n.kind == .lparen and !n.space_before else false;
    if (c.kind == .atom and method and oneOf(p.kind, &.{ .ident, .number, .string, .rparen, .rbracket, .rsquiggly })) return "";
    return " ";
}

fn isOpener(k: TokenType) bool {
    return oneOf(k, &.{ .lparen, .lbracket, .lsquiggly, .kw_do });
}

/// `end` only counts when it closes a `do` block; `collectItems` turns every
/// other one into an `.ident`
fn isCloser(k: TokenType) bool {
    return oneOf(k, &.{ .rparen, .rbracket, .rsquiggly, .kw_end });
}

/// true when `k` can end an expression, so postfix `?` hugs it
fn endsExpr(k: TokenType) bool {
    return oneOf(k, &.{ .ident, .number, .string, .atom, .attribute, .rparen, .rbracket, .rsquiggly, .kw_end });
}

/// an expression left open at end of line
fn isContinuationTail(k: TokenType) bool {
    if (oneOf(k, &.{
        .kw_and,
        .kw_or,
        .kw_not,
        .kw_band,
        .kw_bor,
        .kw_bxor,
        .kw_shl,
        .kw_shr,
        .kw_orelse,
        .kw_in,
        .kw_when,
    })) return true;
    // punctuation that classifies as an operator but doesnt continue
    if (oneOf(k, &.{
        .attribute,
        .dot,
        .dotdot,
        .comma,
        .semicolon,
        .lparen,
        .rparen,
        .lbracket,
        .rbracket,
        .lsquiggly,
        .rsquiggly,
        .huh,
        .bang,
        .interp_open,
        .interp_close,
    })) return false;
    return k.classify() == .operator;
}
