const std = @import("std");
const ast = @import("ast.zig");

pub const LexError = struct {
    kind: Kind,
    span: ast.Span,
    message: []const u8,

    pub const Kind = enum {
        UnexpectedCharacter,
        UnterminatedComment,
        UnterminatedString,
        Unknown,
    };
};

pub const LexResult = union(enum) {
    ok: []Token,
    err: LexError,
};

pub const TokenType = enum {
    number,
    string,
    multiline_string,
    backtick_string,
    hash,
    ident,
    kw_const,
    kw_let,
    kw_macro,
    kw_test,
    kw_suite,
    kw_skip,
    kw_struct,
    kw_fn,
    kw_if,
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
    kw_return,
    kw_import,
    kw_spawn,
    kw_join,
    kw_yield,
    kw_and,
    kw_or,
    kw_not,
    kw_comp,
    kw_proc,
    kw_orelse,
    plus,
    minus,
    star,
    slash,
    percent,
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
    dot,
    dotdot,
    colon,
    comma,
    pipe,
    pipe_forward,
    huh,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lsquiggly,
    rsquiggly,
    eof,

    // i think this does perfect hash but prolly not
    pub const of_string = std.StaticStringMap(TokenType).initComptime(.{
        .{ "const", .kw_const },
        .{ "global", .kw_global },
        .{ "let", .kw_let },
        .{ "comp", .kw_comp },
        .{ "proc", .kw_proc },
        .{ "macro", .kw_macro },
        .{ "test", .kw_test },
        .{ "suite", .kw_suite },
        .{ "skip", .kw_skip },
        .{ "struct", .kw_struct },
        .{ "fn", .kw_fn },
        .{ "if", .kw_if },
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
        .{ "return", .kw_return },
        .{ "import", .kw_import },
        .{ "spawn", .kw_spawn },
        .{ "join", .kw_join },
        .{ "yield", .kw_yield },
        .{ "and", .kw_and },
        .{ "or", .kw_or },
        .{ "not", .kw_not },
        .{ "orelse", .kw_orelse },
    });
};

pub const Token = struct {
    type: TokenType,
    text: []const u8,
    line: u32,
    column: u32,
    start: usize,
    end: usize,

    pub fn span(self: Token) ast.Span {
        return .{
            .start = self.start,
            .end = self.end,
            .line = self.line,
            .column = self.column,
        };
    }
};

pub const testing = struct {
    pub const ExpectedToken = struct {
        t: TokenType,
        v: ?[]const u8 = null,
    };

    pub fn expectTokens(source: []const u8, expected: []const ExpectedToken) !void {
        const tokens = try lex(std.heap.page_allocator, source);
        defer {
            for (tokens) |tok| {
                if (tok.type == .string or tok.type == .backtick_string or tok.type == .multiline_string) {
                    std.heap.page_allocator.free(tok.text);
                }
            }
            std.heap.page_allocator.free(tokens);
        }

        try std.testing.expectEqual(expected.len, tokens.len);
        for (expected, tokens, 0..) |want, got, i| {
            try std.testing.expectEqual(want.t, got.type);
            if (want.v) |text| {
                try std.testing.expectEqualStrings(text, got.text);
            }
            _ = i;
        }
    }
    pub fn expectTypes(source: []const u8, expected: []const TokenType) !void {
        const tokens = try lex(std.heap.page_allocator, source);
        defer {
            for (tokens) |tok| {
                if (tok.type == .string or tok.type == .backtick_string or tok.type == .multiline_string) {
                    std.heap.page_allocator.free(tok.text);
                }
            }
            std.heap.page_allocator.free(tokens);
        }

        try std.testing.expectEqual(expected.len, tokens.len);
        for (expected, tokens) |want, got| {
            try std.testing.expectEqual(want, got.type);
        }
    }
};

pub fn lex(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var lexer = Lexer.init(source, allocator);
    var tokens = try std.ArrayList(Token).initCapacity(allocator, 32);
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = try lexer.next();
        try tokens.append(allocator, token);
        if (token.type == .eof) break;
    }

    return tokens.toOwnedSlice(allocator);
}

pub fn lexReport(allocator: std.mem.Allocator, source: []const u8) !LexResult {
    var lexer = Lexer.init(source, allocator);
    var tokens = try std.ArrayList(Token).initCapacity(allocator, 32);
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = lexer.next() catch |err| {
            // your lexer obj should always be managed by an arena
            // , and therefore shouldn't take 1000s of cpu cycles up by deallocating
            // but just to be safe,
            tokens.deinit(allocator);
            return .{ .err = lexer.lexFailure(err) };
        };
        try tokens.append(allocator, token);
        if (token.type == .eof) break;
    }

    return .{ .ok = try tokens.toOwnedSlice(allocator) };
}

const Lexer = struct {
    source: []const u8,
    alloc: std.mem.Allocator,
    pos: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    line_start: bool = true,
    pending_error_span: ?ast.Span = null,

    fn init(source: []const u8, alloc: std.mem.Allocator) Lexer {
        return .{ .source = source, .alloc = alloc };
    }

    fn next(self: *Lexer) !Token {
        while (!self.atEnd()) {
            const c = self.peek();
            if (std.ascii.isWhitespace(c)) {
                _ = self.advance();
                continue;
            }
            if (c == '#') {
                if (self.peekN(1) == '#') {
                    try self.skipMultilineComment();
                    continue;
                }
                while (!self.atEnd() and self.peek() != '\n') _ = self.advance();
                continue;
            }
            break;
        }

        if (self.atEnd()) return self.makeToken(.eof, self.pos, self.pos, 0, 0);

        const start = self.pos;
        const line = self.line;
        const column = self.column;
        const c = self.advance();

        return switch (c) {
            '|' => if (self.matchChar('>'))
                self.makeToken(.pipe_forward, start, self.pos, line, column)
            else
                self.makeToken(.pipe, start, self.pos, line, column),
            '+' => if (self.matchChar('='))
                self.makeToken(.plus_assign, start, self.pos, line, column)
            else
                self.makeToken(.plus, start, self.pos, line, column),
            '-' => if (self.matchChar('='))
                self.makeToken(.minus_assign, start, self.pos, line, column)
            else if (std.ascii.isDigit(self.peek()))
                self.lexNumberSigned(start, line, column)
            else
                self.makeToken(.minus, start, self.pos, line, column),
            '*' => if (self.matchChar('='))
                self.makeToken(.star_assign, start, self.pos, line, column)
            else
                self.makeToken(.star, start, self.pos, line, column),
            '/' => if (self.matchChar('='))
                self.makeToken(.slash_assign, start, self.pos, line, column)
            else
                self.makeToken(.slash, start, self.pos, line, column),
            '%' => if (self.matchChar('='))
                self.makeToken(.percent_assign, start, self.pos, line, column)
            else
                self.makeToken(.percent, start, self.pos, line, column),
            ':' => if (self.peekIsIdentStart())
                self.lexHash(start, line, column)
            else
                self.makeToken(.colon, start, self.pos, line, column),
            '=' => if (self.matchChar('='))
                self.makeToken(.eq, start, self.pos, line, column)
            else
                self.makeToken(.assign, start, self.pos, line, column),
            '!' => if (self.matchChar('='))
                self.makeToken(.neq, start, self.pos, line, column)
            else
                return error.UnexpectedCharacter,
            '<' => if (self.matchChar('='))
                self.makeToken(.lte, start, self.pos, line, column)
            else
                self.makeToken(.lt, start, self.pos, line, column),
            '>' => if (self.matchChar('='))
                self.makeToken(.gte, start, self.pos, line, column)
            else
                self.makeToken(.gt, start, self.pos, line, column),
            '"' => if (self.matchTripleQuote())
                self.lexMultilineString(start, line, column)
            else
                self.lexString(start, line, column),
            '\'' => self.lexSingleLineString(start, line, column),
            '`' => self.lexBacktickString(start, line, column),

            '$' => return error.UnexpectedCharacter,
            '@' => if (self.peekIsIdentStart())
                self.lexAtIdent(start, line, column)
            else
                return error.UnexpectedCharacter,
            '(' => self.makeToken(.lparen, start, self.pos, line, column),
            ')' => self.makeToken(.rparen, start, self.pos, line, column),
            '[' => self.makeToken(.lbracket, start, self.pos, line, column),
            ']' => self.makeToken(.rbracket, start, self.pos, line, column),
            '{' => self.makeToken(.lsquiggly, start, self.pos, line, column),
            '}' => self.makeToken(.rsquiggly, start, self.pos, line, column),
            ',' => self.makeToken(.comma, start, self.pos, line, column),
            '.' => if (self.matchChar('.'))
                self.makeToken(.dotdot, start, self.pos, line, column)
            else
                self.makeToken(.dot, start, self.pos, line, column),
            '?' => self.makeToken(.huh, start, self.pos, line, column),
            else => {
                if (std.ascii.isDigit(c)) return self.lexNumber(start, line, column);
                if (isIdentStart(c)) return self.lexIdent(start, line, column);
                return error.UnexpectedCharacter;
            },
        };
    }

    fn lexFailure(self: *const Lexer, err: anyerror) LexError {
        const span = self.pending_error_span orelse self.currentSpan();
        return switch (err) {
            error.UnexpectedCharacter => .{ .kind = .UnexpectedCharacter, .span = span, .message = "unexpected character" },
            error.UnterminatedComment => .{ .kind = .UnterminatedComment, .span = span, .message = "unterminated multiline comment" },
            error.UnterminatedString => .{ .kind = .UnterminatedString, .span = span, .message = "unterminated string" },
            else => .{ .kind = .Unknown, .span = span, .message = "lexing failed" },
        };
    }

    fn currentSpan(self: *const Lexer) ast.Span {
        if (self.pos == 0) {
            return .{ .start = 0, .end = 0, .line = self.line, .column = self.column };
        }

        const start = self.pos - 1;
        return .{ .start = start, .end = self.pos, .line = self.line, .column = self.column -| 1 };
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
            self.line_start = true;
        } else {
            self.column += 1;
            if (c != ' ' and c != '\t' and c != '\r') self.line_start = false;
        }
        return c;
    }

    fn matchChar(self: *Lexer, c: u8) bool {
        if (self.peek() != c) return false;
        _ = self.advance();
        return true;
    }

    fn matchTripleQuote(self: *Lexer) bool {
        if (self.peek() != '"' or self.peekN(1) != '"') return false;
        _ = self.advance();
        _ = self.advance();
        return true;
    }

    fn skipMultilineComment(self: *Lexer) !void {
        self.pending_error_span = .{
            .start = self.pos,
            .end = self.pos + 2,
            .line = self.line,
            .column = self.column,
        };
        _ = self.advance();
        _ = self.advance();
        while (!self.atEnd()) {
            if (self.peek() == '#' and self.peekN(1) == '#') {
                _ = self.advance();
                _ = self.advance();
                self.pending_error_span = null;
                return;
            }
            _ = self.advance();
        }
        return error.UnterminatedComment;
    }

    fn lexHash(self: *Lexer, start: usize, line: u32, column: u32) !Token {
        while (isIdentContinue(self.peek())) _ = self.advance();
        return self.makeToken(.hash, start, self.pos, line, column);
    }

    fn lexNumber(self: *Lexer, start: usize, line: u32, column: u32) Token {
        while (std.ascii.isDigit(self.peek())) _ = self.advance();
        if (self.peek() == '.' and self.peekN(1) != '.' and std.ascii.isDigit(self.peekN(1))) {
            _ = self.advance();
            while (std.ascii.isDigit(self.peek())) _ = self.advance();
        }
        if (isIdentContinue(self.peek())) _ = self.advance();
        return self.makeToken(.number, start, self.pos, line, column);
    }

    fn lexNumberSigned(self: *Lexer, start: usize, line: u32, column: u32) Token {
        while (std.ascii.isDigit(self.peek())) _ = self.advance();
        if (self.peek() == '.' and self.peekN(1) != '.' and std.ascii.isDigit(self.peekN(1))) {
            _ = self.advance();
            while (std.ascii.isDigit(self.peek())) _ = self.advance();
        }
        if (isIdentContinue(self.peek())) _ = self.advance();
        return self.makeToken(.number, start, self.pos, line, column);
    }

    fn lexString(self: *Lexer, start: usize, line: u32, column: u32) !Token {
        self.pending_error_span = .{ .start = start, .end = start + 1, .line = line, .column = column };
        var buf = try std.ArrayList(u8).initCapacity(self.alloc, 16);
        defer buf.deinit(self.alloc);
        while (!self.atEnd()) {
            const c = self.advance();
            if (c == '\\') {
                if (self.atEnd()) return error.UnterminatedString;
                const escaped = self.advance();
                const replacement: u8 = switch (escaped) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    else => {
                        try buf.append(self.alloc, '\\');
                        try buf.append(self.alloc, escaped);
                        continue;
                    },
                };
                try buf.append(self.alloc, replacement);
                continue;
            }
            if (c == '"') {
                const text = try buf.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(text);
                return .{
                    .type = .string,
                    .text = text,
                    .line = line,
                    .column = column,
                    .start = start,
                    .end = self.pos,
                };
            }
            try buf.append(self.alloc, c);
        }
        return error.UnterminatedString;
    }

    fn lexSingleLineString(self: *Lexer, start: usize, line: u32, column: u32) !Token {
        self.pending_error_span = .{
            .start = start,
            .end = start + 1,
            .line = line,
            .column = column,
        };
        var buf = try std.ArrayList(u8).initCapacity(self.alloc, 16);
        defer buf.deinit(self.alloc);
        while (!self.atEnd()) {
            const c = self.advance();
            if (c == '\n') {
                const text = try buf.toOwnedSlice(self.alloc);
                self.pending_error_span = null;
                return .{
                    .type = .string,
                    .text = text,
                    .line = line,
                    .column = column,
                    .start = start,
                    .end = self.pos - 1,
                };
            }
            if (c == '\'') {
                const text = try buf.toOwnedSlice(self.alloc);
                self.pending_error_span = null;
                return .{
                    .type = .string,
                    .text = text,
                    .line = line,
                    .column = column,
                    .start = start,
                    .end = self.pos,
                };
            }
            try buf.append(self.alloc, c);
        }
        return error.UnterminatedString;
    }

    fn lexMultilineString(self: *Lexer, start: usize, line: u32, column: u32) !Token {
        self.pending_error_span = .{ .start = start, .end = start + 3, .line = line, .column = column };
        var buf = try std.ArrayList(u8).initCapacity(self.alloc, 64);
        defer buf.deinit(self.alloc);
        while (!self.atEnd()) {
            if (self.peek() == '"' and self.peekN(1) == '"' and self.peekN(2) == '"') {
                _ = self.advance();
                _ = self.advance();
                _ = self.advance();
                const text = try buf.toOwnedSlice(self.alloc);
                self.pending_error_span = null;
                return .{
                    .type = .multiline_string,
                    .text = text,
                    .line = line,
                    .column = column,
                    .start = start,
                    .end = self.pos,
                };
            }
            try buf.append(self.alloc, self.advance());
        }
        return error.UnterminatedString;
    }

    fn lexBacktickString(self: *Lexer, start: usize, line: u32, column: u32) !Token {
        self.pending_error_span = .{ .start = start, .end = start + 1, .line = line, .column = column };
        var buf = try std.ArrayList(u8).initCapacity(self.alloc, 16);
        defer buf.deinit(self.alloc);
        while (!self.atEnd()) {
            const c = self.advance();
            if (c == '\\') {
                if (self.atEnd()) return error.UnterminatedString;
                const escaped = self.advance();
                const replacement: u8 = switch (escaped) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '`' => '`',
                    else => {
                        try buf.append(self.alloc, '\\');
                        try buf.append(self.alloc, escaped);
                        continue;
                    },
                };
                try buf.append(self.alloc, replacement);
                continue;
            }
            if (c == '`') {
                const text = try buf.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(text);
                self.pending_error_span = null;
                return .{
                    .type = .backtick_string,
                    .text = text,
                    .line = line,
                    .column = column,
                    .start = start,
                    .end = self.pos,
                };
            }
            try buf.append(self.alloc, c);
        }
        return error.UnterminatedString;
    }

    fn lexIdent(self: *Lexer, start: usize, line: u32, column: u32) Token {
        while (isIdentContinue(self.peek())) _ = self.advance();
        const text = self.source[start..self.pos];
        const kind = TokenType.of_string.get(text) orelse .ident;
        return .{
            .type = kind,
            .text = text,
            .line = line,
            .column = column,
            .start = start,
            .end = self.pos,
        };
    }

    fn lexAtIdent(self: *Lexer, start: usize, line: u32, column: u32) Token {
        while (isIdentContinue(self.peek())) _ = self.advance();
        const text = self.source[start..self.pos];
        return .{
            .type = .ident,
            .text = text,
            .line = line,
            .column = column,
            .start = start,
            .end = self.pos,
        };
    }

    fn makeToken(self: *Lexer, kind: TokenType, start: usize, end: usize, line: u32, column: u32) Token {
        return .{
            .type = kind,
            .text = self.source[start..end],
            .line = line,
            .column = column,
            .start = start,
            .end = end,
        };
    }

    fn peekIsIdentStart(self: *Lexer) bool {
        return isIdentStart(self.peek());
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c) or c == '!' or c == '?';
}

test "lexes calls with sigils and hash literals" {
    try testing.expectTokens("if @foo(0) == :WriteDenied @bar(1)", &.{
        .{ .t = .kw_if, .v = "if" },
        .{ .t = .ident, .v = "@foo" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .number, .v = "0" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .eq, .v = "==" },
        .{ .t = .hash, .v = ":WriteDenied" },
        .{ .t = .ident, .v = "@bar" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .number, .v = "1" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes macros and pipe-forward" {
    try testing.expectTokens("const call_it = macro `` `@foo(0)` |> print", &.{
        .{ .t = .kw_const, .v = "const" },
        .{ .t = .ident, .v = "call_it" },
        .{ .t = .assign, .v = "=" },
        .{ .t = .kw_macro, .v = "macro" },
        .{ .t = .backtick_string, .v = "" },
        .{ .t = .backtick_string, .v = "@foo(0)" },
        .{ .t = .pipe_forward, .v = "|>" },
        .{ .t = .ident, .v = "print" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes multiline strings" {
    const allocator = std.heap.page_allocator;
    const tokens = try lex(allocator,
        \\"""hello
        \\world"""
    );
    defer {
        allocator.free(tokens[0].text);
        allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.multiline_string, tokens[0].type);
    try std.testing.expectEqualStrings(
        \\hello
        \\world
    , tokens[0].text);
}

test "lexes float numbers and range without conflict" {
    try testing.expectTokens("1.25 0..10", &.{
        .{ .t = .number, .v = "1.25" },
        .{ .t = .number, .v = "0" },
        .{ .t = .dotdot, .v = ".." },
        .{ .t = .number, .v = "10" },
        .{ .t = .eof, .v = "" },
    });
}

const t = @import("testing.zig");
test "lexes match type and text" {
    const source = "match :true | (1 + 1) / (2 * 2) == 4 :good | 1 + 8 == 2 :bad";
    try t.expectTypes(source, &.{ .kw_match, .hash, .pipe, .lparen, .number, .plus, .number, .rparen, .slash, .lparen, .number, .star, .number, .rparen, .eq, .number, .hash, .pipe, .number, .plus, .number, .eq, .number, .hash, .eof });
    try t.expectTokens(source, &.{
        .{ .t = .kw_match, .v = "match" },
        .{ .t = .hash, .v = ":true" },
        .{ .t = .pipe, .v = "|" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .number, .v = "1" },
        .{ .t = .plus, .v = "+" },
        .{ .t = .number, .v = "1" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .slash, .v = "/" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .number, .v = "2" },
        .{ .t = .star, .v = "*" },
        .{ .t = .number, .v = "2" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .eq, .v = "==" },
        .{ .t = .number, .v = "4" },
        .{ .t = .hash, .v = ":good" },
        .{ .t = .pipe, .v = "|" },
        .{ .t = .number, .v = "1" },
        .{ .t = .plus, .v = "+" },
        .{ .t = .number, .v = "8" },
        .{ .t = .eq, .v = "==" },
        .{ .t = .number, .v = "2" },
        .{ .t = .hash, .v = ":bad" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes multiline block syntax" {
    try t.expectTypes(
        \\do
        \\    sys.print "hello"
        \\    if @peek(idx) == :ok :good else :bad
        \\end
    , &.{
        .kw_do,
        .ident,
        .dot,
        .ident,
        .string,
        .kw_if,
        .ident,
        .lparen,
        .ident,
        .rparen,
        .eq,
        .hash,
        .hash,
        .kw_else,
        .hash,
        .kw_end,
        .eof,
    });
}

test "lexes declarations loop return and import" {
    try t.expectTypes(
        \\do
        \\    const sys = import "sys"
        \\    const pluralise = fn(n) n
        \\    let num: int = loop(x) do return len(@consume(idx + 1)) end
        \\end
    , &.{
        .kw_do,
        .kw_const,
        .ident,
        .assign,
        .kw_import,
        .string,
        .kw_const,
        .ident,
        .assign,
        .kw_fn,
        .lparen,
        .ident,
        .rparen,
        .ident,
        .kw_let,
        .ident,
        .colon,
        .ident,
        .assign,
        .kw_loop,
        .lparen,
        .ident,
        .rparen,
        .kw_do,
        .kw_return,
        .ident,
        .lparen,
        .ident,
        .lparen,
        .ident,
        .plus,
        .number,
        .rparen,
        .rparen,
        .kw_end,
        .kw_end,
        .eof,
    });
}

test "lexes fiber keywords" {
    try t.expectTypes(
        \\ spawn join yield
    , &.{
        .kw_spawn,
        .kw_join,
        .kw_yield,
        .eof,
    });
}

test "lexes struct keyword" {
    try t.expectTypes(
        \\ struct User do name: string end
    , &.{
        .kw_struct,
        .ident,
        .kw_do,
        .ident,
        .colon,
        .ident,
        .kw_end,
        .eof,
    });
}

test "lexes test keyword" {
    try t.expectTypes(
        \\ test "smoke" do ok? end
    , &.{
        .kw_test,
        .string,
        .kw_do,
        .ident,
        .kw_end,
        .eof,
    });
}

test "lexes macro literals and pipe-forward" {
    try t.expectTypes(
        \\do
        \\    const dup = macro `` `@peek(0)`
        \\    |> print
        \\end
    , &.{
        .kw_do,
        .kw_const,
        .ident,
        .assign,
        .kw_macro,
        .backtick_string,
        .backtick_string,
        .pipe_forward,
        .ident,
        .kw_end,
        .eof,
    });
}

test "lexes function block with multiline string and table" {
    try t.expectTokens(
        \\fn(msg: str) do
        \\    sys.print """hello
        \\world"""
        \\    {message = msg, status = :ok}
        \\end
    , &.{
        .{ .t = .kw_fn, .v = "fn" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .ident, .v = "msg" },
        .{ .t = .colon, .v = ":" },
        .{ .t = .ident, .v = "str" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .kw_do, .v = "do" },
        .{ .t = .ident, .v = "sys" },
        .{ .t = .dot, .v = "." },
        .{ .t = .ident, .v = "print" },
        .{ .t = .multiline_string, .v =
        \\hello
        \\world
        },
        .{ .t = .lsquiggly, .v = "{" },
        .{ .t = .ident, .v = "message" },
        .{ .t = .assign, .v = "=" },
        .{ .t = .ident, .v = "msg" },
        .{ .t = .comma, .v = "," },
        .{ .t = .ident, .v = "status" },
        .{ .t = .assign, .v = "=" },
        .{ .t = .hash, .v = ":ok" },
        .{ .t = .rsquiggly, .v = "}" },
        .{ .t = .kw_end, .v = "end" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes comments as whitespace including multiline comments" {
    try t.expectTypes(
        \\do # line comment
        \\    ## comment
        \\    adsf
        \\    eeee ##
        \\    let x = 1
        \\end
    , &.{
        .kw_do,
        .kw_let,
        .ident,
        .assign,
        .number,
        .kw_end,
        .eof,
    });
}

test "lexes ident with special symbols" {
    try t.expectTypes(
        \\ one? two!
    , &.{
        .ident,
        .ident,
        .eof,
    });
}

test "lexer reports unterminated strings comments and unexpected characters" {
    try std.testing.expectError(error.UnterminatedString, lex(std.testing.allocator, "\"unterminated"));
    try std.testing.expectError(error.UnterminatedComment, lex(std.testing.allocator, "## never closed"));
    try std.testing.expectError(error.UnexpectedCharacter, lex(std.testing.allocator, "@"));
    try std.testing.expectError(error.UnexpectedCharacter, lex(std.testing.allocator, "!"));
    try std.testing.expectError(error.UnexpectedCharacter, lex(std.testing.allocator, "$"));
}

test "token span includes line column start end" {
    const tokens = try lex(std.testing.allocator, "const x = 1\nlet y = 2");
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenType.kw_const, tokens[0].type);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].line);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].column);
    try std.testing.expectEqual(@as(usize, 0), tokens[0].start);
    try std.testing.expectEqual(@as(usize, 5), tokens[0].end);

    try std.testing.expectEqual(TokenType.kw_let, tokens[4].type);
    const span = tokens[4].span();
    try std.testing.expectEqual(@as(u32, 2), span.line);
    try std.testing.expectEqual(@as(u32, 1), span.column);
    try std.testing.expectEqual(@as(usize, 12), span.start);
    try std.testing.expectEqual(@as(usize, 15), span.end);
}

test "lexes string with newline escape" {
    const tokens = try lex(std.heap.page_allocator, "\"hello\\nworld\"");
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) std.heap.page_allocator.free(tok.text);
        }
        std.heap.page_allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hello\nworld", tokens[0].text);
}

test "unterminated string span points at opening quote" {
    const report = try lexReport(std.testing.allocator,
        \\  
        \\  "unterminated
    );
    try std.testing.expect(report == .err);
    try std.testing.expectEqual(LexError.Kind.UnterminatedString, report.err.kind);
    try std.testing.expectEqual(@as(u32, 2), report.err.span.line);
    try std.testing.expectEqual(@as(u32, 3), report.err.span.column);
}

test "unterminated multiline comment span points at opening hashes" {
    const report = try lexReport(std.testing.allocator,
        \\  
        \\  ## never closed
    );
    try std.testing.expect(report == .err);
    try std.testing.expectEqual(LexError.Kind.UnterminatedComment, report.err.kind);
    try std.testing.expectEqual(@as(u32, 2), report.err.span.line);
    try std.testing.expectEqual(@as(u32, 3), report.err.span.column);
}

test "lexes string with tab escape" {
    const tokens = try lex(std.heap.page_allocator, "\"hi\\tworld\"");
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) std.heap.page_allocator.free(tok.text);
        }
        std.heap.page_allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hi\tworld", tokens[0].text);
}

test "lexes string with backslash escape" {
    const tokens = try lex(std.heap.page_allocator, "\"path\\\\to\\\\file\"");
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) std.heap.page_allocator.free(tok.text);
        }
        std.heap.page_allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("path\\to\\file", tokens[0].text);
}

test "lexes string with quote escape" {
    const tokens = try lex(std.heap.page_allocator, "\"say \\\"hello\\\"\"");
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) std.heap.page_allocator.free(tok.text);
        }
        std.heap.page_allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("say \"hello\"", tokens[0].text);
}

test "lexes string with carriage return escape" {
    const tokens = try lex(std.heap.page_allocator, "\"line1\\rline2\"");
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) std.heap.page_allocator.free(tok.text);
        }
        std.heap.page_allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("line1\rline2", tokens[0].text);
}

test "lexes single quoted string is raw" {
    const tokens = try lex(std.heap.page_allocator, "'hello\\nworld'");
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) std.heap.page_allocator.free(tok.text);
        }
        std.heap.page_allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hello\\nworld", tokens[0].text);
}

test "lexes backtick string with escapes" {
    const tokens = try lex(std.heap.page_allocator, "`hello\\nworld`");
    defer {
        for (tokens) |tok| {
            if (tok.type == .backtick_string) std.heap.page_allocator.free(tok.text);
        }
        std.heap.page_allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.backtick_string, tokens[0].type);
    try std.testing.expectEqualStrings("hello\nworld", tokens[0].text);
}

test "lexes backtick string with backtick escape" {
    const tokens = try lex(std.heap.page_allocator, "`say \\`hi\\``");
    defer {
        for (tokens) |tok| {
            if (tok.type == .backtick_string) std.heap.page_allocator.free(tok.text);
        }
        std.heap.page_allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.backtick_string, tokens[0].type);
    try std.testing.expectEqualStrings("say `hi`", tokens[0].text);
}

test "lexes string with unknown escape passed through" {
    const tokens = try lex(std.heap.page_allocator, "\"hello\\qworld\"");
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) std.heap.page_allocator.free(tok.text);
        }
        std.heap.page_allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hello\\qworld", tokens[0].text);
}
