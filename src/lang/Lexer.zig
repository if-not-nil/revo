//! zlint-disable line-length
//!
//! lexer? i hardly know her
//!   one pass over source, significant tokens plus trivia plus errors
//!
const std = @import("std");

pub const LexError = struct {
    kind: Kind,
    span: Span,
    message: []const u8,

    pub const Kind = enum {
        UnexpectedCharacter,
        UnterminatedComment,
        UnterminatedString,
        LateModuleDoc,
    };
};

pub const TokenType = enum {
    number,
    // raw `'...'` only single `string`, the rest are modal, see below
    string,
    atom,
    ident,
    kw_const,
    kw_let,
    kw_test,
    kw_suite,
    kw_type,
    kw_fn,
    kw_if,
    kw_unless,
    kw_else,
    kw_match,
    kw_when,
    kw_do,
    kw_end,
    kw_loop,
    kw_for,
    kw_while,
    kw_global,
    kw_in,
    kw_break,
    kw_continue,
    kw_return,
    kw_import,
    kw_spawn,
    kw_yield,
    kw_and,
    kw_or,
    kw_not,
    kw_band,
    kw_bor,
    kw_bxor,
    kw_shl,
    kw_shr,
    kw_comp,
    kw_orelse,
    kw_pub,
    kw_declare,
    plus,
    minus,
    star,
    slash,
    floor_div,
    percent,
    caret,
    caret_assign,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    percent_assign,
    concat,
    concat_assign,
    arrow,
    fat_arrow,
    dot,
    dotdot,
    colon,
    comma,
    semicolon,
    bar,
    pipe_forward,
    huh,
    bang,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lsquiggly,
    rsquiggly,
    comment,
    doc_comment,
    module_doc,
    eof,
    attribute,
    // modal strings lex as sequence:::
    //  `string_start`, parts, interps, `string_end`
    string_start,
    string_part,
    interp_open,
    interp_close,
    string_end,
    // , `ml_*` for multiline
    ml_string_start,
    ml_string_part,
    ml_string_end,
    // non-fatal error placeholder, see `errors`
    invalid,

    /// every `kw_*` tag; derived from the name so it cant drift from the enum
    pub fn isKeyword(self: TokenType) bool {
        return switch (self) {
            inline else => |t| comptime std.mem.startsWith(u8, @tagName(t), "kw_"),
        };
    }

    pub fn classify(self: TokenType) ?TokenClass {
        if (self.isKeyword()) return .keyword;
        return switch (self) {
            .number => .number,
            .string => .string,
            .string_start, .string_part, .string_end => .string,
            .ml_string_start, .ml_string_part, .ml_string_end => .string,
            .interp_open, .interp_close => .operator,
            .atom => .enum_member,
            .comment, .doc_comment => .comment,
            .module_doc => .module_doc,
            .ident, .eof, .invalid => null,
            // punctuation or an attribute
            else => .operator,
        };
    }

    pub const of_string = std.StaticStringMap(TokenType).initComptime(.{
        .{ "const", .kw_const },
        .{ "global", .kw_global },
        .{ "let", .kw_let },
        .{ "comp", .kw_comp },
        // `skip` is an ordinary ident, parser handles it after `test/`
        .{ "test", .kw_test },
        .{ "suite", .kw_suite },
        .{ "type", .kw_type },
        .{ "fn", .kw_fn },
        .{ "if", .kw_if },
        .{ "unless", .kw_unless },
        .{ "else", .kw_else },
        .{ "match", .kw_match },
        .{ "when", .kw_when },
        .{ "do", .kw_do },
        .{ "end", .kw_end },
        .{ "loop", .kw_loop },
        .{ "for", .kw_for },
        .{ "while", .kw_while },
        .{ "in", .kw_in },
        .{ "break", .kw_break },
        .{ "continue", .kw_continue },
        .{ "return", .kw_return },
        .{ "import", .kw_import },
        .{ "spawn", .kw_spawn },
        .{ "yield", .kw_yield },
        .{ "and", .kw_and },
        .{ "or", .kw_or },
        .{ "not", .kw_not },
        .{ "band", .kw_band },
        .{ "bor", .kw_bor },
        .{ "bxor", .kw_bxor },
        .{ "shl", .kw_shl },
        .{ "shr", .kw_shr },
        .{ "orelse", .kw_orelse },
        .{ "pub", .kw_pub },
        .{ "declare", .kw_declare },
    });
};

/// source span; positions originate here at lexing
pub const Span = struct {
    start: usize,
    end: usize,
    line: u32,
    column: u32,

    pub fn merge(a: Span, b: Span) Span {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
            .line = if (a.start <= b.start) a.line else b.line,
            .column = if (a.start <= b.start) a.column else b.column,
        };
    }
};

pub const Token = struct {
    type: TokenType,
    text: []const u8,
    line: u32,
    column: u32,
    start: usize,
    end: usize,
    /// whitespace before this token, for hug checks
    space_before: bool = false,
    /// newline before this token, implies `space_before`
    nl_before: bool = false,
    /// newlines in the gap before this token, blank line when >= 2
    newlines_before: u32 = 0,
    /// leading trivia range into `LexOutput.trivia`, comments only
    /// , whitespace gaps stay implicit via `start`/`end` offsets
    trivia_start: usize = 0,
    trivia_len: usize = 0,

    /// mainly for diagnostic use
    pub fn span(self: Token) Span {
        return .{
            .start = self.start,
            .end = self.end,
            .line = self.line,
            .column = self.column,
        };
    }
};

/// eager lex output, nonfatal
/// , `tokens` ends in eof, `trivia` holds comments in source order
/// , each token points at its leading `trivia` slice plus newline counts
/// , eof carries trailing trivia as its leading slice
pub const LexOutput = struct {
    tokens: []Token,
    trivia: []Token,
    errors: []LexError,

    /// leading comment trivia for `tok`, empty when none
    pub fn leadingTrivia(self: LexOutput, tok: Token) []const Token {
        const end = @min(tok.trivia_start + tok.trivia_len, self.trivia.len);
        const start = @min(tok.trivia_start, end);
        return self.trivia[start..end];
    }

    /// true when a blank line separates `tok` from the previous token
    pub fn hasBlankLine(_: LexOutput, tok: Token) bool {
        return tok.newlines_before >= 2;
    }
};

pub fn freeLexOutput(alloc: std.mem.Allocator, out: LexOutput) void {
    for (out.tokens) |tok| switch (tok.type) {
        .string, .string_part, .ml_string_part => freeTokenStrings(alloc, tok),
        else => {},
    };
    alloc.free(out.tokens);
    alloc.free(out.trivia);
    alloc.free(out.errors);
}

pub fn freeTokenStrings(alloc: std.mem.Allocator, tok: Token) void {
    alloc.free(tok.text);
}

pub const testing = struct {
    pub const ExpectedToken = struct {
        t: TokenType,
        v: ?[]const u8 = null,
    };

    /// free a `lexAt` result made with the testing allocator
    /// , todo: why testing allocator only
    pub fn freeLexed(tokens: []Token) void {
        for (tokens) |tok| switch (tok.type) {
            .string, .string_part, .ml_string_part => freeTokenStrings(std.testing.allocator, tok),
            else => {},
        };
        std.testing.allocator.free(tokens);
    }

    pub fn expectTokens(source: []const u8, expected: []const ExpectedToken) !void {
        const tokens = try lexAt(std.testing.allocator, source);
        defer freeLexed(tokens);

        try std.testing.expectEqual(expected.len, tokens.len);
        for (expected, tokens) |want, got| {
            try std.testing.expectEqual(want.t, got.type);
            if (want.v) |text| {
                try std.testing.expectEqualStrings(text, got.text);
            }
        }
    }

    pub fn expectTypes(source: []const u8, expected: []const TokenType) !void {
        const tokens = try lexAt(std.testing.allocator, source);
        defer freeLexed(tokens);

        try std.testing.expectEqual(expected.len, tokens.len);
        for (expected, tokens) |want, got| {
            try std.testing.expectEqual(want, got.type);
        }
    }
};

/// for syntax highlighting
pub const TokenClass = enum {
    keyword,
    string,
    number,
    function,
    variable,
    operator,
    enum_member,
    comment,
    module_doc,
};

/// true when `text[pos]` is `(`, i.e. paren hugs ident
pub fn identIsFunction(text: []const u8, pos: usize) bool {
    return pos < text.len and text[pos] == '(';
}

/// eager lex of whole source, trivia and errors separated
/// , lazy path uses `next` directly for in-order errors
pub fn lexAll(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!LexOutput {
    var lexer = Lexer.init(source, allocator);
    defer lexer.modes.deinit(allocator);
    var tokens = try std.ArrayList(Token).initCapacity(allocator, 32);
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = try lexer.next();
        try tokens.append(allocator, token);
        if (token.type == .eof) break;
    }

    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .trivia = try lexer.trivia.toOwnedSlice(allocator),
        .errors = try lexer.errors.toOwnedSlice(allocator),
    };
}

/// tokens only; trivia & errors are dropped
/// , trivia ranges are zeroed since the store is freed, gaps stay usable
pub fn lexAt(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]Token {
    const out = try lexAll(allocator, source);
    allocator.free(out.trivia);
    allocator.free(out.errors);
    for (out.tokens) |*t| {
        t.trivia_start = 0;
        t.trivia_len = 0;
    }
    return out.tokens;
}

/// where a token began
const Mark = struct {
    start: usize,
    line: u32,
    column: u32,
};

/// lazy, non-fatal, modal lexer
/// , `next` pulls one significant token, errors to `errors`, comments to `trivia`
const Lexer = @This();

source: []const u8,
alloc: std.mem.Allocator,
/// byte offset in source
pos: usize = 0,
line: u32 = 1,
column: u32 = 1,
/// string/interpolation stack; empty is plain code
modes: std.ArrayList(Frame) = .empty,
/// lex errors in source order (non-fatal; see `invalid` tokens)
errors: std.ArrayList(LexError) = .empty,
/// comments/module_doc in source order
trivia: std.ArrayList(Token) = .empty,
/// set after the first significant (non-trivia) token; rejects late module_doc
emitted_significant: bool = false,
/// whitespace seen since the last significant token
saw_space: bool = false,
saw_newline: bool = false,
/// newlines in the current gap, stamped onto the next significant token
gap_newlines: u32 = 0,
/// trivia len at the last significant token, next token owns the rest
trivia_base: usize = 0,
/// previous significant kind
/// , numbers hugging `.` lex as ints, e.g. `t.0.1` splits into `t . 0 . 1`
prev_kind: ?TokenType = null,

const FrameKind = enum { string, ml_string, interp };

const Frame = struct {
    kind: FrameKind,
    /// opening delimiter position (for unterminated error spans)
    start: usize,
    line: u32,
    column: u32,
    /// interp only: `{` nesting depth inside `#{...}` (1 at open)
    depth: usize = 0,
};

pub fn init(source: []const u8, alloc: std.mem.Allocator) Lexer {
    return .{ .source = source, .alloc = alloc };
}

pub fn deinit(self: *Lexer) void {
    self.modes.deinit(self.alloc);
    self.errors.deinit(self.alloc);
    self.trivia.deinit(self.alloc);
}

/// pull next significant token, never fails except oom
/// , errors go to `errors` with `invalid` placeholder
pub fn next(self: *Lexer) std.mem.Allocator.Error!Token {
    // inside `"..."` / `"""..."""`: literal parts and interp boundaries
    if (self.modes.items.len > 0) {
        const top = self.modes.items[self.modes.items.len - 1];
        if (top.kind == .string or top.kind == .ml_string) {
            return try self.lexStringInterior();
        }
    }

    try self.skipTrivia();

    // unterminated interp at eof, strings handled above
    if (self.atEnd()) {
        if (self.modes.items.len > 0) {
            const top = self.modes.items[self.modes.items.len - 1];
            if (top.kind == .interp) {
                const span: Span = .{ .start = top.start, .end = self.pos, .line = top.line, .column = top.column };
                try self.recordLexError(.UnterminatedString, span, "unterminated string");
                _ = self.modes.pop();
                return try self.invalidToken(span);
            }
        }
        return self.eofToken();
    }

    const m = self.takeMark();
    const c = self.advance();

    return switch (c) {
        '|' => self.twoWay(m, '>', .pipe_forward, .bar),
        '+' => self.twoWay(m, '=', .plus_assign, .plus),
        '-' => if (self.matchChar('='))
            self.finish(m, .minus_assign)
        else
            self.twoWay(m, '>', .arrow, .minus),
        '*' => self.twoWay(m, '=', .star_assign, .star),
        '/' => if (self.matchChar('='))
            self.finish(m, .slash_assign)
        else
            self.twoWay(m, '/', .floor_div, .slash),
        '%' => self.twoWay(m, '=', .percent_assign, .percent),
        '^' => self.twoWay(m, '=', .caret_assign, .caret),
        '~' => self.twoWay(m, '=', .concat_assign, .concat),
        ':' => if (isIdentStart(self.peek()) or isSymbolAtomStart(self.peek()))
            self.lexAtom(m)
        else
            self.finish(m, .colon),
        '=' => if (self.matchChar('='))
            self.finish(m, .eq)
        else
            self.twoWay(m, '>', .fat_arrow, .assign),
        '!' => self.twoWay(m, '=', .neq, .bang),
        '<' => self.twoWay(m, '=', .lte, .lt),
        '>' => self.twoWay(m, '=', .gte, .gt),
        '"' => self.lexQuoteOpen(m),
        '\'' => self.lexSingleLineString(m.start, m.line, m.column),
        '`' => blk: {
            const span = self.spanFromMark(m);
            try self.recordLexError(.UnexpectedCharacter, span, "unexpected character");
            break :blk try self.invalidToken(span);
        },
        '#' => try self.lexHashSignificant(m),
        '@' => if (isIdentStart(self.peek()))
            self.lexAttribute(m)
        else blk: {
            const span = self.spanFromMark(m);
            try self.recordLexError(.UnexpectedCharacter, span, "unexpected character");
            break :blk try self.invalidToken(span);
        },
        '(' => self.finish(m, .lparen),
        ')' => self.finish(m, .rparen),
        '[' => self.finish(m, .lbracket),
        ']' => self.finish(m, .rbracket),
        '{' => self.lexLBrace(m),
        '}' => self.lexRBrace(m),
        ',' => self.finish(m, .comma),
        '.' => self.twoWay(m, '.', .dotdot, .dot),
        ';' => self.finish(m, .semicolon),
        '?' => self.finish(m, .huh),
        else => {
            if (std.ascii.isDigit(c)) return try self.lexNumber(m.start, m.line, m.column);
            if (isIdentStart(c)) return self.lexIdent(m.start, m.line, m.column);
            const span = self.spanFromMark(m);
            try self.recordLexError(.UnexpectedCharacter, span, "unexpected character");
            return try self.invalidToken(span);
        },
    };
}

/// mark plus whitespace flags for next token, resets saw_*
fn takeMark(self: *Lexer) Mark {
    const m: Mark = .{ .start = self.pos, .line = self.line, .column = self.column };
    return m;
}

fn spanFromMark(self: *const Lexer, m: Mark) Span {
    return .{ .start = m.start, .end = self.pos, .line = m.line, .column = m.column };
}

/// skip whitespace and trivia, record `space_before`/`nl_before`
/// , `#*...*#` stays significant for parser
fn skipTrivia(self: *Lexer) std.mem.Allocator.Error!void {
    while (!self.atEnd()) {
        const c = self.peek();
        if (c == '\r' and self.peekN(1) == '\n') {
            self.saw_space = true;
            self.saw_newline = true;
            self.gap_newlines += 1;
            _ = self.advance();
            _ = self.advance();
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            self.saw_space = true;
            if (c == '\n' or c == '\r') {
                self.saw_newline = true;
                self.gap_newlines += 1;
            }
            _ = self.advance();
            continue;
        }
        if (c != '#') break;
        // `#*` doc comments are significant; everything else is trivia
        if (self.peekN(1) == '*') break;
        try self.lexTriviaComment();
    }
}

/// one newline inside trivia, counts toward the pending gap
fn noteTriviaNewline(self: *Lexer) void {
    self.saw_space = true;
    self.saw_newline = true;
    self.gap_newlines += 1;
}

/// stamp pending gap onto a significant token, then reset the gap
fn stampGap(self: *Lexer, tok: *Token) void {
    tok.space_before = self.saw_space;
    tok.nl_before = self.saw_newline;
    tok.newlines_before = self.gap_newlines;
    tok.trivia_start = self.trivia_base;
    tok.trivia_len = self.trivia.items.len - self.trivia_base;
    self.saw_space = false;
    self.saw_newline = false;
    self.gap_newlines = 0;
    self.trivia_base = self.trivia.items.len;
}

/// `#` trivia: line `#...`, block `##...##`, module `#!...!#`
/// , doc `#*...*#` is not trivia, caller keeps it significant
fn lexTriviaComment(self: *Lexer) std.mem.Allocator.Error!void {
    const start = self.pos;
    const line = self.line;
    const column = self.column;
    _ = self.advance();
    // module doc `#! ... !#`
    if (self.peek() == '!') {
        _ = self.advance();
        const err_span: Span = .{ .start = start, .end = self.pos, .line = line, .column = column };
        if (self.emitted_significant) {
            try self.recordLexError(.LateModuleDoc, err_span, "module doc must be at the start of the file");
        }
        var body_start = self.pos;
        while (!self.atEnd()) {
            if (self.peek() == '!' and self.peekN(1) == '#') {
                if (body_start < self.pos and self.source[body_start] == '\n') body_start += 1;
                const body_end = self.pos;
                _ = self.advance();
                _ = self.advance();
                // module docs are trivia now, span covers delimiters
                var mod_tok = self.triviaToken(.module_doc, start, self.pos, line, column);
                mod_tok.text = self.source[body_start..body_end];
                try self.trivia.append(self.alloc, mod_tok);
                self.saw_space = true;
                return;
            }
            if (self.source[self.pos] == '\n') self.noteTriviaNewline();
            _ = self.advance();
        }
        // unterminated spans run to eof for repl continue check
        const unterminated: Span = .{ .start = start, .end = self.pos, .line = line, .column = column };
        try self.recordLexError(.UnterminatedComment, unterminated, "unterminated multiline comment");
        try self.trivia.append(self.alloc, self.triviaToken(.comment, start, self.pos, line, column));
        self.saw_space = true;
        return;
    }
    // block `## ... ##`
    if (self.peek() == '#') {
        _ = self.advance();
        while (!self.atEnd()) {
            if (self.peek() == '#' and self.peekN(1) == '#') {
                _ = self.advance();
                _ = self.advance();
                try self.trivia.append(self.alloc, self.triviaToken(.comment, start, self.pos, line, column));
                self.saw_space = true;
                return;
            }
            if (self.source[self.pos] == '\n') self.noteTriviaNewline();
            _ = self.advance();
        }
        const unterminated: Span = .{ .start = start, .end = self.pos, .line = line, .column = column };
        try self.recordLexError(.UnterminatedComment, unterminated, "unterminated multiline comment");
        try self.trivia.append(self.alloc, self.triviaToken(.comment, start, self.pos, line, column));
        self.saw_space = true;
        return;
    }
    // line `#...` to newline, newline stays whitespace
    while (!self.atEnd() and self.peek() != '\n') _ = self.advance();
    try self.trivia.append(self.alloc, self.triviaToken(.comment, start, self.pos, line, column));
    self.saw_space = true;
}

/// `#` in significant position, only `#*...*#` arrives here
fn lexHashSignificant(self: *Lexer, m: Mark) std.mem.Allocator.Error!Token {
    // m already consumed `#`; pos is after it
    if (self.peek() == '*') {
        _ = self.advance();
        var body_start = self.pos;
        while (!self.atEnd()) {
            if (self.peek() == '*' and self.peekN(1) == '#') {
                if (body_start < self.pos and self.source[body_start] == '\n') body_start += 1;
                const body_end = self.pos;
                _ = self.advance();
                _ = self.advance();
                // span covers delimiters, text stays body
                var tok = self.makeToken(.doc_comment, m.start, self.pos, m.line, m.column);
                tok.text = self.source[body_start..body_end];
                return tok;
            }
            _ = self.advance();
        }
        const unterminated: Span = .{ .start = m.start, .end = self.pos, .line = m.line, .column = m.column };
        try self.recordLexError(.UnterminatedComment, unterminated, "unterminated multiline comment");
        return try self.invalidToken(unterminated);
    }
    const span = self.spanFromMark(m);
    try self.recordLexError(.UnexpectedCharacter, span, "unexpected character");
    return try self.invalidToken(span);
}

fn recordLexError(self: *Lexer, kind: LexError.Kind, span: Span, message: []const u8) std.mem.Allocator.Error!void {
    try self.errors.append(self.alloc, .{ .kind = kind, .span = span, .message = message });
}

fn invalidToken(self: *Lexer, span: Span) std.mem.Allocator.Error!Token {
    const text = if (span.end > span.start and span.end <= self.source.len)
        self.source[span.start..span.end]
    else
        "";
    return self.makeTokenAt(.invalid, text, span);
}

fn eofToken(self: *Lexer) Token {
    // eof carries end position; never sets emitted_significant
    return self.makeToken(.eof, self.pos, self.pos, self.line, self.column);
}

/// token from `m` to current pos, stamps whitespace flags
fn finish(self: *Lexer, m: Mark, kind: TokenType) Token {
    return self.makeToken(kind, m.start, self.pos, m.line, m.column);
}

/// `yes` if the next char is `second` (consuming it), else `no`
fn twoWay(self: *Lexer, m: Mark, second: u8, yes: TokenType, no: TokenType) Token {
    const kind = if (self.matchChar(second)) yes else no;
    return self.finish(m, kind);
}

/// `"` opens modal string, `"""` opens multiline
fn lexQuoteOpen(self: *Lexer, m: Mark) Token {
    // m already consumed the first `"`; check for `"""`
    if (self.peek() == '"' and self.peekN(1) == '"') {
        _ = self.advance();
        _ = self.advance();
        const tok = self.finish(m, .ml_string_start);
        self.modes.append(self.alloc, .{ .kind = .ml_string, .start = m.start, .line = m.line, .column = m.column }) catch {};
        return tok;
    }
    const tok = self.finish(m, .string_start);
    self.modes.append(self.alloc, .{ .kind = .string, .start = m.start, .line = m.line, .column = m.column }) catch {};
    return tok;
}

fn lexLBrace(self: *Lexer, m: Mark) Token {
    const tok = self.finish(m, .lsquiggly);
    if (self.modes.items.len > 0 and self.modes.items[self.modes.items.len - 1].kind == .interp) {
        self.modes.items[self.modes.items.len - 1].depth += 1;
    }
    return tok;
}

fn lexRBrace(self: *Lexer, m: Mark) Token {
    if (self.modes.items.len > 0 and self.modes.items[self.modes.items.len - 1].kind == .interp) {
        const top = &self.modes.items[self.modes.items.len - 1];
        if (top.depth <= 1) {
            const tok = self.finish(m, .interp_close);
            _ = self.modes.pop();
            return tok;
        }
        top.depth -= 1;
    }
    return self.finish(m, .rsquiggly);
}

fn atEnd(self: *Lexer) bool {
    return self.pos >= self.source.len;
}

fn peek(self: *Lexer) u8 {
    return if (self.atEnd()) 0 else self.source[self.pos];
}

fn peekN(self: *Lexer, offset: usize) u8 {
    const idx = self.pos + offset;
    return if (idx >= self.source.len) 0 else self.source[idx];
}

fn advance(self: *Lexer) u8 {
    const c = self.source[self.pos];
    self.pos += 1;
    if (c == '\n') {
        self.line += 1;
        self.column = 1;
    } else if ((c & 0xC0) != 0x80) {
        // utf-8 continuation bytes dont start a new column
        self.column += 1;
    }
    return c;
}

fn matchChar(self: *Lexer, c: u8) bool {
    if (self.peek() != c) return false;
    _ = self.advance();
    return true;
}

/// `:name`, `:name?`, or symbol atom like `:+` / `:<=`
/// , ident atoms stop at operators, so `:a==:b` is `:a == :b`
fn lexAtom(self: *Lexer, m: Mark) Token {
    if (isIdentStart(self.peek())) {
        self.consumeIdentBody();
        self.consumeIdentSuffix();
    } else {
        while (isSymbolAtomStart(self.peek())) _ = self.advance();
    }
    return self.finish(m, .atom);
}

/// exponent marker only counts when digits follow
/// , `1else` and `0x1p` dont swallow the letter
fn exponentFollows(self: *Lexer) bool {
    const n1 = self.peekN(1);
    if (std.ascii.isDigit(n1)) return true;
    return (n1 == '+' or n1 == '-') and std.ascii.isDigit(self.peekN(2));
}

fn lexNumber(self: *Lexer, start: usize, line: u32, column: u32) std.mem.Allocator.Error!Token {
    var base: u8 = 10;

    // keep `t.0.1` split, hugging dot lexes as number
    const hugging_dot = !self.saw_space and self.prev_kind != null and self.prev_kind.? == .dot;

    if (self.source[start] == '0') {
        switch (self.peek()) {
            'x', 'X' => {
                base = 16;
                _ = self.advance();
            },
            'b', 'B' => {
                base = 2;
                _ = self.advance();
            },
            'o', 'O' => {
                base = 8;
                _ = self.advance();
            },
            else => {},
        }
    }

    while (true) {
        const c = self.peek();
        const n1 = self.peekN(1);
        if (std.ascii.isDigit(c) or c == '_') {
            _ = self.advance();
        } else if (base == 16 and std.ascii.isHex(c)) {
            _ = self.advance();
        } else if (!hugging_dot and c == '.' and (std.ascii.isDigit(n1) or (base == 16 and std.ascii.isHex(n1)))) {
            // `.` joins number only when digit follows
            // , `t.0.name` and `1.max` split at dots
            _ = self.advance();
        } else if (!hugging_dot and (c == 'e' or c == 'E') and base == 10 and self.exponentFollows()) {
            _ = self.advance();
            if (self.peek() == '+' or self.peek() == '-') _ = self.advance();
        } else if (!hugging_dot and (c == 'p' or c == 'P') and base == 16 and self.exponentFollows()) {
            _ = self.advance();
            if (self.peek() == '+' or self.peek() == '-') _ = self.advance();
        } else {
            break;
        }
    }

    // reject `1__2` and `1.5.5` here for recovery
    const text = self.source[start..self.pos];
    if (isMalformedNumber(text)) {
        const span: Span = .{ .start = start, .end = self.pos, .line = line, .column = column };
        try self.recordLexError(.UnexpectedCharacter, span, "invalid number literal");
        return try self.invalidToken(span);
    }

    return self.makeToken(.number, start, self.pos, line, column);
}

fn isMalformedNumber(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "__") != null) return true;
    if (text.len > 0 and (text[0] == '_' or text[text.len - 1] == '_')) return true;
    var dots: usize = 0;
    for (text) |c| {
        if (c == '.') dots += 1;
    }

    // `1.5.5` (or hex with two dots) is not one number
    if (dots > 1) return true;
    if (std.mem.indexOf(u8, text, "_.") != null) return true;
    if (std.mem.indexOf(u8, text, "._") != null) return true;
    return false;
}

/// never fails, truncated escapes stay literal
fn lexStringEscapeInto(self: *Lexer, buf: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    if (self.atEnd()) {
        try buf.append(self.alloc, '\\');
        return;
    }
    const from = self.pos - 1;
    var offset = from;
    switch (std.zig.string_literal.parseEscapeSequence(self.source, &offset)) {
        .success => |lit| {
            const is_byte = from + 1 < self.source.len and self.source[from + 1] == 'x';
            while (self.pos < offset) _ = self.advance();
            var enc: [4]u8 = undefined;
            const bytes: []const u8 = if (is_byte) blk: {
                enc[0] = @intCast(lit);
                break :blk enc[0..1];
            } else blk: {
                const n = std.unicode.utf8Encode(lit, &enc) catch {
                    try buf.append(self.alloc, '\\');
                    return;
                };
                break :blk enc[0..n];
            };
            try buf.appendSlice(self.alloc, bytes);
        },
        .failure => {
            // `\#{` escapes to literal `#{`
            if (from + 2 < self.source.len and
                self.source[from + 1] == '#' and self.source[from + 2] == '{')
            {
                try buf.appendSlice(self.alloc, "#{");
                _ = self.advance();
                _ = self.advance();
                return;
            }
            try buf.append(self.alloc, '\\');
            _ = self.advance();
            try buf.append(self.alloc, self.source[self.pos - 1]);
        },
    }
}

fn lexStringInterior(self: *Lexer) std.mem.Allocator.Error!Token {
    const top = self.modes.items[self.modes.items.len - 1];
    const multiline = top.kind == .ml_string;
    const part_kind: TokenType = if (multiline) .ml_string_part else .string_part;
    const end_kind: TokenType = if (multiline) .ml_string_end else .string_end;

    const part_start = self.pos;
    const part_line = self.line;
    const part_col = self.column;

    var buf = try std.ArrayList(u8).initCapacity(self.alloc, 16);
    defer buf.deinit(self.alloc);

    while (!self.atEnd()) {
        if (multiline) {
            if (self.peek() == '"' and self.peekN(1) == '"' and self.peekN(2) == '"') break;
        } else {
            if (self.peek() == '"') break;
        }
        if (self.peek() == '#' and self.peekN(1) == '{') break;

        const c = self.peek();
        if (c == '\\') {
            _ = self.advance();
            try self.lexStringEscapeInto(&buf);
            continue;
        }
        if ((c == '{' or c == '}') and self.peekN(1) == c) {
            try buf.append(self.alloc, c);
            _ = self.advance();
            _ = self.advance();
            continue;
        }
        if (c == '\r') {
            if (self.peekN(1) == '\n') {
                _ = self.advance();
                _ = self.advance();
            } else {
                _ = self.advance();
                self.line += 1;
                self.column = 1;
            }
            try buf.append(self.alloc, '\n');
            continue;
        }
        try buf.append(self.alloc, c);
        _ = self.advance();
    }

    if (buf.items.len > 0) {
        const text = try buf.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(text);
        self.emitted_significant = true;
        self.prev_kind = part_kind;
        return .{
            .type = part_kind,
            .text = text,
            .line = part_line,
            .column = part_col,
            .start = part_start,
            .end = self.pos,
        };
    }

    // empty literal: boundary token or unterminated error
    if (self.atEnd()) {
        const span: Span = .{ .start = top.start, .end = self.pos, .line = top.line, .column = top.column };
        try self.recordLexError(.UnterminatedString, span, "unterminated string");
        _ = self.modes.pop();
        return try self.invalidToken(span);
    }
    if (self.peek() == '#' and self.peekN(1) == '{') {
        const m: Mark = .{ .start = self.pos, .line = self.line, .column = self.column };
        _ = self.advance();
        _ = self.advance();
        self.modes.append(self.alloc, .{ .kind = .interp, .start = m.start, .line = m.line, .column = m.column, .depth = 1 }) catch {};
        self.emitted_significant = true;
        self.prev_kind = .interp_open;
        return .{
            .type = .interp_open,
            .text = self.source[m.start..self.pos],
            .line = m.line,
            .column = m.column,
            .start = m.start,
            .end = self.pos,
        };
    }
    {
        const m: Mark = .{ .start = self.pos, .line = self.line, .column = self.column };
        if (multiline) {
            _ = self.advance();
            _ = self.advance();
            _ = self.advance();
        } else {
            _ = self.advance();
        }
        _ = self.modes.pop();
        self.emitted_significant = true;
        self.prev_kind = end_kind;
        return .{
            .type = end_kind,
            .text = self.source[m.start..self.pos],
            .line = m.line,
            .column = m.column,
            .start = m.start,
            .end = self.pos,
        };
    }
}

/// `'...'` raw string, no escapes or interp, one `string` token
fn lexSingleLineString(self: *Lexer, start: usize, line: u32, column: u32) std.mem.Allocator.Error!Token {
    var buf = try std.ArrayList(u8).initCapacity(self.alloc, 16);
    defer buf.deinit(self.alloc);
    while (!self.atEnd()) {
        if (self.peek() == '\r') {
            if (self.peekN(1) == '\n') {
                _ = self.advance();
                _ = self.advance();
            } else {
                _ = self.advance();
                self.line += 1;
                self.column = 1;
            }
            try buf.append(self.alloc, '\n');
            continue;
        }
        const c = self.advance();
        if (c == '\'') {
            const text = try buf.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(text);
            var tok = Token{
                .type = .string,
                .text = text,
                .line = line,
                .column = column,
                .start = start,
                .end = self.pos,
            };
            self.stampGap(&tok);
            self.emitted_significant = true;
            self.prev_kind = .string;
            return tok;
        }
        try buf.append(self.alloc, c);
    }
    const span: Span = .{ .start = start, .end = self.pos, .line = line, .column = column };
    try self.recordLexError(.UnterminatedString, span, "unterminated string");
    return try self.invalidToken(span);
}

fn isBlank(line: []const u8) bool {
    for (line) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r') return false;
    }
    return true;
}

pub fn dedentMultiline(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0 or text[0] != '\n') return try alloc.dupe(u8, text);

    const body = text[1..];
    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 8);
    defer lines.deinit(alloc);

    // blank lines gont vote on indent
    var min_indent: ?usize = null;
    var iter = std.mem.splitScalar(u8, body, '\n');

    while (iter.next()) |line| {
        try lines.append(alloc, line);
        if (isBlank(line)) continue;
        var count: usize = 0;

        for (line) |ch| {
            if (ch == ' ' or ch == '\t') {
                count += 1;
            } else {
                break;
            }
        }

        if (min_indent) |m| {
            if (count < m) min_indent = count;
        } else {
            min_indent = count;
        }
    }

    const strip = min_indent orelse 0;
    // dedent in place, short blank lines go empty
    for (lines.items) |*line| {
        if (line.len > strip) {
            line.* = line.*[strip..];
        } else {
            line.* = "";
        }
    }
    // strip trailing blanks after dedent
    while (lines.items.len > 0 and isBlank(lines.items[lines.items.len - 1])) {
        _ = lines.pop();
    }

    var buf = try std.ArrayList(u8).initCapacity(alloc, 64);
    errdefer buf.deinit(alloc);

    for (lines.items, 0..) |line, i| {
        if (i > 0) try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, line);
    }

    return try buf.toOwnedSlice(alloc);
}

fn consumeIdentBody(self: *Lexer) void {
    while (isIdentContinue(self.peek())) _ = self.advance();
}

/// one optional trailing `?` or `!`, `!` before `=` left alone
/// , so `x!=y` is `x != y`
fn consumeIdentSuffix(self: *Lexer) void {
    const c = self.peek();
    if (c != '?' and c != '!') return;
    if (c == '!' and self.peekN(1) == '=') return;
    _ = self.advance();
}

fn lexIdent(self: *Lexer, start: usize, line: u32, column: u32) Token {
    self.consumeIdentBody();
    self.consumeIdentSuffix();
    const text = self.source[start..self.pos];
    const kind = TokenType.of_string.get(text) orelse .ident;
    return self.makeToken(kind, start, self.pos, line, column);
}

fn lexAttribute(self: *Lexer, m: Mark) Token {
    self.consumeIdentBody();
    return self.finish(m, .attribute);
}

fn makeToken(self: *Lexer, kind: TokenType, start: usize, end: usize, line: u32, column: u32) Token {
    var tok = Token{
        .type = kind,
        .text = self.source[start..end],
        .line = line,
        .column = column,
        .start = start,
        .end = end,
    };
    self.stampGap(&tok);
    if (kind != .eof) self.emitted_significant = true;
    self.prev_kind = kind;
    return tok;
}

fn makeTokenAt(self: *Lexer, kind: TokenType, text: []const u8, span: Span) Token {
    var tok = Token{
        .type = kind,
        .text = text,
        .line = span.line,
        .column = span.column,
        .start = span.start,
        .end = span.end,
    };
    self.stampGap(&tok);
    self.emitted_significant = true;
    self.prev_kind = kind;
    return tok;
}

fn triviaToken(self: *Lexer, kind: TokenType, start: usize, end: usize, line: u32, column: u32) Token {
    // trivia never carries whitespace flags and never marks significance
    return .{
        .type = kind,
        .text = self.source[start..end],
        .line = line,
        .column = column,
        .start = start,
        .end = end,
    };
}

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// body chars only;
/// the trailing `?`/`!` is handled by consumeIdentSuffixb
pub fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

pub fn isSymbolAtomStart(c: u8) bool {
    return switch (c) {
        '-', '+', '*', '/', '=', '<', '>', '.', '@', '$', '~', '^', '?', '!' => true,
        else => false,
    };
}

// tests

test "every kw_ token has a source spelling" {
    inline for (@typeInfo(TokenType).@"enum".field_names) |f| {
        if (comptime std.mem.startsWith(u8, f, "kw_")) {
            try std.testing.expectEqual(
                @as(?TokenType, @field(TokenType, f)),
                TokenType.of_string.get(f[3..]),
            );
        }
    }
}

test "skip is an ordinary identifier" {
    try testing.expectTypes("skip", &.{ .ident, .eof });
}

test "bang before equals is not part of an identifier" {
    try testing.expectTypes("x!=y", &.{ .ident, .neq, .ident, .eof });
    try testing.expectTokens("inc!", &.{ .{ .t = .ident, .v = "inc!" }, .{ .t = .eof } });
    try testing.expectTokens("empty?", &.{ .{ .t = .ident, .v = "empty?" }, .{ .t = .eof } });
}

test "numbers only take a dot when a digit follows" {
    try testing.expectTypes("t.0.1", &.{ .ident, .dot, .number, .dot, .number, .eof });
    try testing.expectTypes("t.0.name", &.{ .ident, .dot, .number, .dot, .ident, .eof });
    try testing.expectTypes("1.max", &.{ .number, .dot, .ident, .eof });
    try testing.expectTokens("1.5", &.{ .{ .t = .number, .v = "1.5" }, .{ .t = .eof } });
    try testing.expectTokens("1e5", &.{ .{ .t = .number, .v = "1e5" }, .{ .t = .eof } });
    try testing.expectTypes("0..10", &.{ .number, .dotdot, .number, .eof });
}

test "exponent letter needs digits after it" {
    try testing.expectTypes("1else", &.{ .number, .kw_else, .eof });
}

test "eof token carries the end position" {
    const tokens = try lexAt(std.testing.allocator, "ab\ncd");
    defer testing.freeLexed(tokens);
    const eof = tokens[tokens.len - 1];

    try std.testing.expectEqual(TokenType.eof, eof.type);
    try std.testing.expectEqual(@as(u32, 2), eof.line);
    try std.testing.expectEqual(@as(u32, 3), eof.column);
}

test "hex escapes decode to a single byte" {
    const tokens = try lexAt(std.testing.allocator, "\"\\xff\"");
    defer testing.freeLexed(tokens);

    // modal: start, part, end, eof
    try testing.expectTypes("\"\\xff\"", &.{ .string_start, .string_part, .string_end, .eof });
    try std.testing.expectEqualSlices(u8, &.{0xff}, tokens[1].text);
}

test "unicode escapes still encode as utf-8" {
    const tokens = try lexAt(std.testing.allocator, "\"\\u{e9}\"");
    defer testing.freeLexed(tokens);
    try std.testing.expectEqualStrings("\u{e9}", tokens[1].text);
}

test "multiline dedent ignores short blank lines" {
    const raw = "\n    a\n  \n    b\n";
    const dedented = try dedentMultiline(std.testing.allocator, raw);

    defer std.testing.allocator.free(dedented);
    try std.testing.expectEqualStrings("a\n\nb", dedented);
}

test "modal strings lex without re-scanning" {
    // `"hi #{name}!"` is start, part, open, ident, close, part, end
    try testing.expectTypes("\"hi #{name}!\"", &.{
        .string_start, .string_part, .interp_open, .ident, .interp_close, .string_part, .string_end, .eof,
    });
    // `{{`/`}}` collapse; `\#{` stays literal (no interp)
    try testing.expectTypes("\"a {{b}} c\\#{d}\"", &.{
        .string_start, .string_part, .string_end, .eof,
    });
}

test "token spans stay inside the source" {
    const cases = [_][]const u8{
        "let x = 1 # hi\n",
        "print \"hi #{name}!\"",
        "f ##x##(1)",
        "\"a {{b}} c\"",
        "`a + %x`",
        "\"\"\"\n  hello\n  \"\"\"",
    };
    for (cases) |src| {
        const out = try lexAll(std.testing.allocator, src);
        defer freeLexOutput(std.testing.allocator, out);
        for (out.tokens) |t| {
            try std.testing.expect(t.start <= t.end and t.end <= src.len);
        }
        for (out.trivia) |t| {
            try std.testing.expect(t.start <= t.end and t.end <= src.len);
        }
    }
}

test "columns count characters, not bytes" {
    const tokens = try lexAt(std.testing.allocator, "\"\u{e9}\" x");
    defer testing.freeLexed(tokens);

    //  start, part, end, ident(x), eof
    try std.testing.expectEqual(@as(u32, 5), tokens[3].column);
}

test "crlf normalizes inside strings" {
    const tokens = try lexAt(std.testing.allocator, "\"a\r\nb\"");
    defer testing.freeLexed(tokens);

    try std.testing.expectEqualStrings("a\nb", tokens[1].text);
}

test "unterminated comment spans reach eof" {
    const out = try lexAll(std.testing.allocator, "#* never closed");
    defer freeLexOutput(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.errors.len);
    const e = out.errors[0];

    try std.testing.expectEqual(LexError.Kind.UnterminatedComment, e.kind);
    try std.testing.expectEqual(@as(usize, 0), e.span.start);
    try std.testing.expectEqual(@as(usize, 15), e.span.end);
}

test "span merge keeps earliest start regardless argument order" {
    const left: Span = .{ .start = 10, .end = 20, .line = 2, .column = 5 };
    const right: Span = .{ .start = 2, .end = 8, .line = 1, .column = 3 };

    const merged_lr = Span.merge(left, right);
    const merged_rl = Span.merge(right, left);

    try std.testing.expectEqual(@as(usize, 2), merged_lr.start);
    try std.testing.expectEqual(@as(usize, 20), merged_lr.end);
    try std.testing.expectEqual(@as(u32, 1), merged_lr.line);
    try std.testing.expectEqual(@as(u32, 3), merged_lr.column);

    try std.testing.expectEqual(merged_lr.start, merged_rl.start);
    try std.testing.expectEqual(merged_lr.end, merged_rl.end);
    try std.testing.expectEqual(merged_lr.line, merged_rl.line);
    try std.testing.expectEqual(merged_lr.column, merged_rl.column);
}
