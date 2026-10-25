//!
//! parser? i hardly know her
//!
const std = @import("std");

const cst = @import("cst.zig");
const CstNode = cst.CstNode;
const CstKind = cst.CstKind;
const Node = cst.CstNode;
const Span = Lexer.Span;
const Lexer = @import("Lexer.zig");
const testing_helpers = @import("test_helpers.zig");
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;
const type_syntax = @import("type_syntax.zig");

pub const Options = struct {
    repl_mode: bool = false,
};

const BP = struct {
    const assign = 5;
    const compound = 5; // same as assign, right-assoc
    const comp = 0;
    const pipe = 15;
    const range = 36; // `a < b..c` is `(a < b)..c`
    const bare_call = 70; // `f "str"` or `f { a = 1 }`
    const try_op = 80; // postfix `x?`, err propagation
};

const diagnostic = @import("./diagnostic.zig");

// left < right = left-assoc    a + b + c :== (a + b) + c
// left > right = right-assoc   a = b = c :== a = (b = c)
const BindingPower = struct {
    left: u8,
    right: u8,
    op: cst.BinOp,
};

// short-circuit, flow control
const LogicalBinding = struct {
    left: u8,
    right: u8,
};

pub const ParseFailure = diagnostic.Diagnostic(Kind);

pub const Kind = enum {
    LexUnexpectedCharacter,
    LexUnterminatedComment,
    LexUnterminatedString,
    LexLateModuleDoc,
    LexUnknown,
    UnexpectedToken,
    ExpectedIdentifier,
    ExpectedMatchArm,
    InvalidNumber,
    UnknownAttribute,
};

pub const ParseResult = union(enum) {
    ok: *Node,
    err: ParseFailure,
};

fn failureError(kind: Kind) anyerror {
    return switch (kind) {
        .LexUnexpectedCharacter => error.UnexpectedCharacter,
        .LexUnterminatedComment => error.UnterminatedComment,
        .LexUnterminatedString => error.UnterminatedString,
        .LexLateModuleDoc => error.LateModuleDoc,
        .UnexpectedToken => error.UnexpectedToken,
        .ExpectedIdentifier => error.ExpectedIdentifier,
        .ExpectedMatchArm => error.ExpectedMatchArm,
        .UnknownAttribute => error.UnknownAttribute,
        .LexUnknown, .InvalidNumber => error.ParseFailed,
    };
}

const SyntaxInfo = struct { kind: Kind, message: []const u8 };

/// recoverable errors and their diagnostics
fn syntaxInfo(err: anyerror) ?SyntaxInfo {
    return switch (err) {
        error.UnexpectedToken => .{ .kind = .UnexpectedToken, .message = "unexpected token" },
        error.ExpectedIdentifier => .{ .kind = .ExpectedIdentifier, .message = "expected identifier" },
        error.ExpectedMatchArm => .{
            .kind = .ExpectedMatchArm,
            .message = "match expression requires at least one arm",
        },
        error.UnknownAttribute => .{ .kind = .UnknownAttribute, .message = "unknown attribute" },
        else => null,
    };
}

// -- [api] -------------------------------------------------------------------

pub fn parseTokens(allocator: std.mem.Allocator, tokens: []const Token, opts: Options) anyerror!*Node {
    switch (try parseTokensReport(allocator, tokens, opts)) {
        .ok => |expr| return expr,
        .err => |failure| return failureError(failure.kind),
    }
}

/// lex + parse in one call, pure frontend entry
/// , baselib-free
pub fn parseSource(allocator: std.mem.Allocator, source: []const u8, opts: Options) !*Node {
    switch (try parseSourceReport(allocator, source, opts)) {
        .ok => |expr| return expr,
        .err => |failure| return failureError(failure.kind),
    }
}

fn lexKindToParseKind(kind: Lexer.LexError.Kind) Kind {
    return switch (kind) {
        .UnexpectedCharacter => .LexUnexpectedCharacter,
        .UnterminatedComment => .LexUnterminatedComment,
        .UnterminatedString => .LexUnterminatedString,
        .LateModuleDoc => .LexLateModuleDoc,
    };
}

pub fn parseSourceReport(allocator: std.mem.Allocator, source: []const u8, opts: Options) !ParseResult {
    return parseSourceReportWithWarnings(allocator, source, opts, null);
}

pub fn parseSourceReportWithWarnings(
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
    warnings: ?*?diagnostic.Report,
) !ParseResult {
    // lazy pull via `tokenAt`
    // errors interleave in src order
    var lexer = Lexer.init(source, allocator);
    defer lexer.deinit();

    var parser = Parser{ .alloc = allocator, .opts = opts, .lexer = &lexer, .source = source };
    parser.buf = try std.ArrayList(Token).initCapacity(allocator, 32);
    try parser.initErrors();

    const root = parser.parse() catch |err| {
        const info = syntaxInfo(err) orelse return err;
        try parser.recordError(info.kind, info.message, parser.peek().span());
        return .{ .err = try parser.finishFailure() };
    };
    if (parser.had_errors) {
        return .{ .err = try parser.finishFailure() };
    }

    // trivia transfers to the root
    // tokens index into it for comments
    // so the tree stays lossless bc i wanna match gofmt
    //
    // the transfer empties the lexers list, leaving the deferred deinit a nop
    if (root.kind == .root)
        root.kind.root.trivia = try lexer.trivia.toOwnedSlice(allocator);

    if (warnings) |out| {
        if (parser.warnings.items.len > 0) {
            const parts = try parser.warnings.toOwnedSlice(allocator);
            const msg = for (parts) |part| {
                if (part == .warn) break part.warn;
            } else "";
            out.* = .{
                .parts = parts,
                .message = msg,
                .severity = .warning,
                .code = parser.first_warn_code,
                .source = source,
            };
        }
    }
    return .{ .ok = root };
}

/// repl helper
/// true when `source` looks unfinished
/// , eof-anchored strings/comments, trailing continuations, unclosed delims
pub fn needsMoreInput(source: []const u8, alloc: std.mem.Allocator) bool {
    const out = Lexer.lexAll(alloc, source) catch return false;
    defer Lexer.freeLexOutput(alloc, out);
    for (out.errors) |e| switch (e.kind) {
        .UnterminatedString, .UnterminatedComment => {
            if (e.span.end != source.len) return false;
        },
        else => return false,
    };

    if (out.errors.len > 0) return true;
    if (out.tokens.len < 2) return false; // just eof

    // tokens end in eof, so last real one is before it
    if (continuesAfter(out.tokens[out.tokens.len - 2].type)) return true;
    return hasUnclosedDelim(out.tokens);
}

/// trailing tokens that promise more input
fn continuesAfter(t: TokenType) bool {
    return switch (t) {
        .assign,
        .plus_assign,
        .minus_assign,
        .star_assign,
        .slash_assign,
        .percent_assign,
        .caret_assign,
        .concat_assign,
        .comma,
        .arrow,
        .fat_arrow,
        .pipe_forward,
        .dotdot,
        .dot,
        .bar,
        .eq,
        .neq,
        .lt,
        .gt,
        .lte,
        .gte,
        .plus,
        .minus,
        .star,
        .slash,
        .floor_div,
        .percent,
        .caret,
        .concat,
        .kw_band,
        .kw_bor,
        .kw_bxor,
        .kw_shl,
        .kw_shr,
        .kw_and,
        .kw_or,
        .kw_orelse,
        .kw_not,
        .attribute,
        .lparen,
        .lbracket,
        .lsquiggly,
        .kw_do,
        => true,
        else => false,
    };
}

/// true when closers still owed; `t.end` after `.` is a field
fn hasUnclosedDelim(tokens: []const Token) bool {
    const Frame = enum { paren, bracket, brace, do_block };
    var stack: [32]Frame = undefined;
    var depth: usize = 0;
    var prev: TokenType = .eof;
    for (tokens) |tok| {
        switch (tok.type) {
            .eof, .invalid => break,
            .lparen => {
                if (depth >= stack.len) return true;
                stack[depth] = .paren;
                depth += 1;
            },
            .lbracket => {
                if (depth >= stack.len) return true;
                stack[depth] = .bracket;
                depth += 1;
            },
            .lsquiggly => {
                if (depth >= stack.len) return true;
                stack[depth] = .brace;
                depth += 1;
            },
            .kw_do => {
                if (depth >= stack.len) return true;
                stack[depth] = .do_block;
                depth += 1;
            },
            .rparen => {
                if (depth == 0 or stack[depth - 1] != .paren) return false;
                depth -= 1;
            },
            .rbracket => {
                if (depth == 0 or stack[depth - 1] != .bracket) return false;
                depth -= 1;
            },
            .rsquiggly => {
                if (depth == 0 or stack[depth - 1] != .brace) return false;
                depth -= 1;
            },
            .kw_end => {
                if (prev == .dot) continue; // `t.end` field, not a closer
                if (depth == 0 or stack[depth - 1] != .do_block) return false;
                depth -= 1;
            },
            else => {},
        }
        prev = tok.type;
    }
    return depth > 0;
}

pub fn parseTokensReport(alloc: std.mem.Allocator, tokens: []const Token, opts: Options) anyerror!ParseResult {
    var parser = Parser{ .alloc = alloc, .tokens = tokens, .opts = opts };
    try parser.initErrors();
    const root = parser.parse() catch |err| {
        const info = syntaxInfo(err) orelse return err;
        const msg = try alloc.dupe(u8, info.message);
        errdefer alloc.free(msg);

        var b = diagnostic.DiagnosticBuilder.init(alloc);
        errdefer b.deinit();
        try b.err(msg, parser.peek().span());
        return .{ .err = .{
            .kind = info.kind,
            .report = try b.finish(msg, .err),
        } };
    };
    if (parser.had_errors) {
        return .{ .err = try parser.finishFailure() };
    }
    return .{ .ok = root };
}

/// recursive descent + pratt hybrid
/// , lazy `parseSourceReport` via `tokenAt`; eager `parseTokensReport` for tests
const Parser = @This();
alloc: std.mem.Allocator,
tokens: []const Token = &.{},
pos: usize = 0,
lexer: ?*Lexer = null,
buf: std.ArrayList(Token) = .empty,
done: bool = false,
lex_recorded: usize = 0,
source: []const u8 = "",
stop_token: ?TokenType = null,
allow_bare_calls: bool = true, // permit `f "str"`, disabled in pattern positions
stop_on_stmt_start: bool = false, // treat statement-starting tokens as expr boundaries
errors: std.ArrayList(diagnostic.Part) = .empty,
error_depths: std.ArrayList(usize) = .empty,
warnings: std.ArrayList(diagnostic.Part) = .empty,
first_warn_code: ?[]const u8 = null,
first_error_kind: ?Kind = null,
had_errors: bool = false,
depth: usize = 0,
opts: Options = .{},
scope_depth: usize = 0,

fn bindingScope(self: *const Parser) bool {
    return self.opts.repl_mode and self.scope_depth == 0;
}

fn initErrors(self: *Parser) !void {
    self.errors = try std.ArrayList(diagnostic.Part).initCapacity(self.alloc, 8);
    self.error_depths = try std.ArrayList(usize).initCapacity(self.alloc, 8);
}

/// lazy pull
/// buffer on demand, record lexer errors in order
pub fn tokenAt(self: *Parser, i: usize) Token {
    if (self.lexer == null) {
        return self.tokens[@min(i, self.tokens.len - 1)];
    }
    const lx = self.lexer.?;
    while (i >= self.buf.items.len and !self.done) {
        const t = lx.next() catch {
            // oom only
            // record and stop with eof placeholder
            break;
        };
        self.buf.append(self.alloc, t) catch {
            break;
        };
        // interleave new lexer errors in source order
        while (self.lex_recorded < lx.errors.items.len) {
            const e = lx.errors.items[self.lex_recorded];
            self.lex_recorded += 1;
            self.recordError(lexKindToParseKind(e.kind), e.message, e.span) catch {};
        }
        if (t.type == .eof) self.done = true;
    }
    if (self.buf.items.len == 0) {
        // oom before any token; synthesize eof at 0
        return Token{
            .type = .eof,
            .text = "",
            .line = 1,
            .column = 1,
            .start = 0,
            .end = 0,
        };
    }
    return self.buf.items[@min(i, self.buf.items.len - 1)];
}

fn parse(self: *Parser) anyerror!*CstNode {
    var list = try self.parseExprListUntil(.eof);

    if (!self.check(.eof)) {
        const token = self.peek();
        try self.recordError(.UnexpectedToken, "unexpected token", token.span());
        var skipped = std.ArrayList(Token).empty;
        self.drainToEofInto(&skipped);

        if (skipped.items.len > 0) {
            const err = try self.allocCst(token.span(), .{ .err = .{ .toks = try skipped.toOwnedSlice(self.alloc) } });
            var stmts = std.ArrayList(*CstNode).fromOwnedSlice(list.stmts);
            try stmts.append(self.alloc, err);
            list.stmts = try stmts.toOwnedSlice(self.alloc);
        } else skipped.deinit(self.alloc);
    }

    const eof = self.peek();
    return self.allocCst(cst.spanFromNodes(list.stmts, eof.span()), .{
        .root = .{ .stmts = list.stmts, .semis = list.semis, .eof_tok = eof },
    });
}

fn drainToEofInto(self: *Parser, skipped: *std.ArrayList(Token)) void {
    if (self.lexer == null) {
        while (self.pos < self.tokens.len - 1) {
            skipped.append(self.alloc, self.tokens[self.pos]) catch {};
            self.pos += 1;
        }
        return;
    }
    const from = self.buf.items.len;

    // pull to eof; lexer always terminates
    while (!self.done) {
        _ = self.tokenAt(self.buf.items.len);
    }

    for (self.buf.items[from..]) |t| {
        if (t.type == .eof) break;
        skipped.append(self.alloc, t) catch {};
    }
    self.pos = self.buf.items.len - 1;
}

fn finishFailure(self: *Parser) anyerror!ParseFailure {
    var parts = try self.errors.toOwnedSlice(self.alloc);
    const depths = try self.error_depths.toOwnedSlice(self.alloc);
    defer self.alloc.free(depths);

    // keep deepest errors only
    if (depths.len > 0 and depths.len * 2 == parts.len) {
        var max_depth: usize = 0;
        for (depths) |d| {
            if (d > max_depth) max_depth = d;
        }
        var kept = try std.ArrayList(diagnostic.Part).initCapacity(self.alloc, parts.len);
        defer kept.deinit(self.alloc);
        for (depths, 0..) |d, idx| {
            if (d == max_depth) {
                const base = idx * 2;
                try kept.append(self.alloc, parts[base]);
                try kept.append(self.alloc, parts[base + 1]);
            }
        }
        if (kept.items.len > 0 and kept.items.len < parts.len) {
            self.alloc.free(parts);
            parts = try kept.toOwnedSlice(self.alloc);
        }
    }
    const msg = for (parts) |p| {
        if (p == .@"error") break p.@"error";
    } else "";
    return .{
        .kind = self.first_error_kind orelse .LexUnknown,
        .report = .{
            .parts = parts,
            .message = msg,
        },
    };
}

fn recordError(self: *Parser, kind: Kind, message: []const u8, span: Lexer.Span) !void {
    self.had_errors = true;
    const owned = try self.alloc.dupe(u8, message);
    if (self.first_error_kind == null) self.first_error_kind = kind;
    try self.errors.append(self.alloc, .{ .@"error" = owned });
    try self.errors.append(self.alloc, .{ .span = .{ .span = span, .role = .primary } });
    try self.error_depths.append(self.alloc, self.depth);
}

fn recordSyntaxError(self: *Parser, err: anyerror, token: Token) !void {
    const info = syntaxInfo(err) orelse return err;
    try self.recordError(info.kind, info.message, token.span());
}

fn syncToNextStatement(self: *Parser, terminator: TokenType, skipped: *std.ArrayList(Token)) void {
    if (self.check(terminator) or self.check(.eof)) return;
    const start = self.pos;
    // sync on newlines/`end`; other starts caused cascades
    while (!self.check(terminator) and !self.check(.eof)) {
        if (self.peek().nl_before) break;
        if (self.check(.kw_end)) break;
        skipped.append(self.alloc, self.peek()) catch {};
        self.pos += 1;
    }
    // guarantee progress for caller loop
    if (self.pos == start) {
        skipped.append(self.alloc, self.peek()) catch {};
        self.pos += 1;
    }
}

const max_parse_depth: usize = 256;

/// prefix node, then infix/postfix while binding power allows
/// , below min_bp stops and returns
fn parseExpression(self: *Parser, min_bp: u8) anyerror!*CstNode {
    self.depth += 1;
    defer self.depth -= 1;
    if (self.depth > max_parse_depth) {
        try self.recordError(.UnexpectedToken, "expression too deeply nested", self.peek().span());
        return error.UnexpectedToken;
    }
    var left = try self.parsePrefix();

    while (true) {
        if (self.check(.semicolon)) break;
        if (self.stop_token) |stop| if (self.check(stop)) break;

        // `f "x" "y"` and `g() "x"`
        if (self.allow_bare_calls and isBareCallArgToken(self.peek().type) and !self.peek().nl_before) {
            const kind = cstEffectiveKind(left);
            if (kind == .bare_call or kind == .call or kind == .generic_call or kind == .method_call) {
                const msg = if (kind == .bare_call)
                    "bare calls take exactly one argument; use parentheses for more: `f(\"a\", \"b\")`"
                else
                    "a bare call cannot follow a call result; use parentheses: `f()(\"x\")`";

                try self.recordError(.UnexpectedToken, msg, self.peek().span());
                while (!self.peek().nl_before and isBareCallArgToken(self.peek().type)) {
                    _ = try self.parseBareCallArg();
                }
                continue;
            }
        }

        if (self.stop_on_stmt_start and self.isStatementBoundary(left)) break;

        // `o:m "x"`: colon calls always need parentheses
        if (self.allow_bare_calls and
            cstExprAllowsBareCall(left) and
            self.peek().type == .atom and
            isBareCallArgToken(self.peekAt(1).type) and
            !self.peekAt(1).nl_before)
        {
            try self.recordError(
                .UnexpectedToken,
                "method calls need parentheses: `obj:method(\"x\")`",
                self.peek().span(),
            );
            _ = self.advance();
            _ = try self.parseBareCallArg();
            continue;
        }

        // `f<T> "x"`: generic calls need the `(...)` argument list
        if (self.peek().type == .lt and
            isPathReceiver(left) and
            !self.peek().space_before and
            self.isGenericBareArgAhead())
        {
            try self.recordError(
                .UnexpectedToken,
                "generic calls need parentheses: `f<T>(\"x\")`",
                self.peek().span(),
            );
            while (!self.check(.gt) and !self.check(.eof)) _ = self.advance();
            _ = self.match(.gt);
            _ = try self.parseBareCallArg();
            continue;
        }

        // postfix `obj.field` or `obj.0`
        if (self.match(.dot)) {
            const dot_tok = self.prevToken();
            if (self.peek().type == .number) {
                const num = self.advance();
                const index_value = std.fmt.parseFloat(f64, num.text) catch blk: {
                    try self.recordError(.InvalidNumber, "invalid number literal", num.span());
                    break :blk @as(f64, 0);
                };
                left = try self.allocCst(Span.merge(left.span, num.span()), .{
                    .dotted_index = .{ .object = left, .dot_tok = dot_tok, .num_tok = num, .value = index_value },
                });
            } else {
                const name = try self.expectName();
                left = try self.allocCst(Span.merge(left.span, name.span()), .{
                    .field = .{ .object = left, .dot_tok = dot_tok, .name_tok = name },
                });
            }
            continue;
        }

        // postfix `obj:method(args)`; `:foo(` must hug
        if (self.peek().type == .atom and self.peekAt(1).type == .lparen and !self.peekAt(1).space_before) {
            const method = self.advance();
            const lparen_tok = try self.expect(.lparen);
            const args = try self.parseDelimitedExprList(.rparen);
            const close = try self.expect(.rparen);
            left = try self.allocCst(Span.merge(left.span, close.span()), .{
                .method_call = .{
                    .object = left,
                    .atom_tok = method,
                    .lparen_tok = lparen_tok,
                    .args = args.items,
                    .commas = args.commas,
                    .rparen_tok = close,
                },
            });
            continue;
        }

        // postfix `obj[key]`
        if (self.peek().type == .lbracket) {
            const lbracket_tok = try self.expect(.lbracket);
            const key = try self.parseBracketKey();
            const close = try self.expect(.rbracket);
            left = try self.allocCst(Span.merge(left.span, close.span()), .{
                .index = .{ .object = left, .lbracket_tok = lbracket_tok, .key = key, .rbracket_tok = close },
            });
            continue;
        }

        // postfix generic `f<T>(args)`; brackets must hug, `<` else comparison
        if (self.peek().type == .lt and //
            isPathReceiver(left) and //
            !self.peek().space_before and //
            self.isGenericCallAhead() //
        ) {
            const lt_tok = try self.expect(.lt);
            const tps = try self.parseTypeParamList();
            const lparen_tok = try self.expect(.lparen);
            const args = try self.parseDelimitedExprList(.rparen);
            const close = try self.expect(.rparen);
            left = try self.allocCst(Span.merge(left.span, close.span()), .{
                .generic_call = .{
                    .receiver = left,
                    .lt_tok = lt_tok,
                    .type_args = tps.tps,
                    .commas = tps.commas,
                    .gt_tok = tps.gt_tok,
                    .lparen_tok = lparen_tok,
                    .args = args.items,
                    .arg_commas = args.commas,
                    .rparen_tok = close,
                },
            });
            continue;
        }

        // postfix `f(args)`; callee and `(` must hug
        if (self.peek().type == .lparen and !self.peek().space_before) {
            const lparen_tok = try self.expect(.lparen);
            const args = try self.parseDelimitedExprList(.rparen);
            const close = try self.expect(.rparen);
            left = try self.allocCst(Span.merge(left.span, close.span()), .{
                .call = .{
                    .callee = left,
                    .lparen_tok = lparen_tok,
                    .args = args.items,
                    .commas = args.commas,
                    .rparen_tok = close,
                },
            });
            continue;
        }

        // postfix bare call `f "str"` or `f { a = 1 }`
        if (self.allow_bare_calls and self.isBareCallArgumentStart(left)) {
            const bp: u8 = BP.bare_call;
            if (bp < min_bp) break;
            const arg = try self.parseBareCallArg();
            left = try self.allocCst(Span.merge(left.span, arg.span), .{
                .bare_call = .{ .callee = left, .arg = arg },
            });
            continue;
        }

        // infix `x = y`; right-assoc, lhs becomes pattern in lowering
        if (BP.assign >= min_bp and self.match(.assign)) {
            const eq_tok = self.prevToken();
            const value = try self.parseExpression(BP.assign);
            left = try self.allocCst(Span.merge(left.span, value.span), .{
                .assign = .{ .target = left, .eq_tok = eq_tok, .value = value },
            });
            continue;
        }

        // infix `x += y`; lowered single-eval in compiler
        const comp_binop = compound_assign_table.get(self.peek().type);
        if (BP.compound >= min_bp and comp_binop != null) {
            const binop = comp_binop.?;
            const op_tok = self.advance();

            const right = try self.parseExpression(BP.compound);

            left = try self.allocCst(Span.merge(left.span, right.span), .{
                .compound = .{ .target = left, .op_tok = op_tok, .op = binop, .value = right },
            });
            continue;
        }

        // infix range; stop_token keeps `0..2..10` flat
        if (self.match(.dotdot)) {
            const dot1_tok = self.prevToken();
            const step_or_end = try self.parseStoppingAtDotDot(BP.range);

            const dot2_tok: ?Token = if (self.match(.dotdot)) self.prevToken() else null;
            if (dot2_tok) |_| {
                const end_node = try self.parseExpression(BP.range);
                left = try self.allocCst(Span.merge(left.span, end_node.span), .{
                    .range = .{ .start = left, .dot1_tok = dot1_tok, .mid = step_or_end, .dot2_tok = dot2_tok, .end = end_node },
                });
            } else {
                left = try self.allocCst(Span.merge(left.span, step_or_end.span), .{
                    .range = .{ .start = left, .dot1_tok = dot1_tok, .mid = step_or_end, .dot2_tok = null, .end = null },
                });
            }
            continue;
        }

        // infix `and` `or` `orelse`
        const op = self.peek().type;
        if (logical_binding_table.get(op)) |binding| {
            if (binding.left < min_bp) break;
            const op_tok = self.advance();
            const right = try self.parseExpression(binding.right);
            left = try self.allocCst(Span.merge(left.span, right.span), .{
                .logical = .{ .left = left, .op_tok = op_tok, .op = switch (op) {
                    .kw_and => .and_op,
                    .kw_or => .or_op,
                    .kw_orelse => .orelse_op,
                    else => return error.UnexpectedToken,
                }, .right = right },
            });
            continue;
        }

        // infix `|>`
        if (op == .pipe_forward) {
            const bp: u8 = BP.pipe;
            if (bp < min_bp) break;
            const pipe_tok = self.advance();

            const into_what = self.peek().type;

            const right = if (into_what == .kw_fn)
                try self.parseFnWithBodyMin(self.advance(), bp + 1)
            else
                // rhs binds tighter than pipe so placeholders stay inside
                try self.parseExpression(BP.pipe + 1);

            left = try self.allocCst(Span.merge(left.span, right.span), .{
                .pipe = .{ .left = left, .pipe_tok = pipe_tok, .right = right },
            });
            continue;
        }

        // postfix `x?`
        if (op == .huh) {
            const bp: u8 = BP.try_op;
            if (bp < min_bp) break;
            const question = self.advance();
            left = try self.allocCst(Span.merge(left.span, question.span()), .{
                .try_expr = .{ .expr = left, .qmark_tok = question },
            });
            continue;
        }

        // infix math/compare; lookup bp and recurse
        const binding = infix_binding_table.get(op) orelse break;
        if (binding.left < min_bp) break;
        const op_tok = self.advance();
        const right = try self.parseExpression(binding.right);
        left = try self.allocCst(Span.merge(left.span, right.span), .{
            .binary = .{ .left = left, .op_tok = op_tok, .op = binding.op, .right = right },
        });
    }

    return left;
}

/// stop at `..` so ranges chain
fn parseStoppingAtDotDot(self: *Parser, min_bp: u8) anyerror!*CstNode {
    const prev_stop = self.stop_token;
    self.stop_token = .dotdot;
    defer self.stop_token = prev_stop;
    return self.parseExpression(min_bp);
}

/// literals, keywords, unary ops, and statement forms
fn parsePrefix(self: *Parser) anyerror!*CstNode {
    self.depth += 1;
    defer self.depth -= 1;
    if (self.depth > max_parse_depth) {
        try self.recordError(.UnexpectedToken, "expression too deeply nested", self.peek().span());
        return error.UnexpectedToken;
    }
    const token = self.advance();
    return switch (token.type) {
        .number => blk: {
            const parsed = std.zig.parseNumberLiteral(token.text);
            const value: f64 = switch (parsed) {
                // f64 loses precision past 2^53, so report
                .int => |n| blk2: {
                    const max_safe: i64 = 9007199254740991; // 2^53 - 1
                    if (n > max_safe or n < -max_safe) {
                        try self.recordError(.InvalidNumber, "integer literal too large to represent exactly (use a float)", token.span());
                        break :blk2 @as(f64, 0);
                    }
                    break :blk2 @floatFromInt(n);
                },
                .float => std.fmt.parseFloat(f64, token.text) catch {
                    try self.recordError(.InvalidNumber, "invalid float literal", token.span());
                    break :blk self.allocCst(token.span(), .{ .number = .{ .tok = token, .value = 0, .is_float = false } });
                },
                .big_int => {
                    try self.recordError(.InvalidNumber, "number literal too large", token.span());
                    break :blk self.allocCst(token.span(), .{ .number = .{ .tok = token, .value = 0, .is_float = false } });
                },
                .failure => {
                    try self.recordError(.InvalidNumber, "invalid number literal", token.span());
                    break :blk self.allocCst(token.span(), .{ .number = .{ .tok = token, .value = 0, .is_float = false } });
                },
            };
            const is_float = (parsed == .float);
            if (!std.math.isFinite(value))
                try self.recordError(.InvalidNumber, "number literal too large", token.span());
            break :blk self.allocCst(token.span(), .{ .number = .{ .tok = token, .value = value, .is_float = is_float } });
        },
        .string => self.allocCst(token.span(), .{ .string = .{ .tok = token } }),
        .string_start => self.parseInterpolatedString(token, false),
        .ml_string_start => self.parseInterpolatedString(token, true),
        .invalid => self.allocCst(token.span(), .{ .err = .{ .toks = try self.dupeToks(&.{token}) } }),
        .atom => self.allocCst(token.span(), .{ .atom = .{ .tok = token } }),
        .doc_comment => self.parseDocAttr(token),
        .ident => self.allocCst(token.span(), .{ .ident = .{ .tok = token } }),
        .kw_const, .kw_global, .kw_let, .kw_test, .kw_suite, .kw_declare => self.parseDecl(token),
        .kw_fn => self.parseFnWithBodyMin(token, 0),
        .minus => self.parseUnary(.negate, 60, token),
        .kw_not => self.parseUnary(.not, 35, token),
        .lparen => self.parseParenExpr(token),
        .kw_if => self.parseConditional(token, false),
        .kw_unless => self.parseConditional(token, true),
        .kw_match => self.parseMatch(token),
        .kw_do => self.parseBlock(token),
        .kw_loop => self.parseLoop(token),
        .kw_for => self.parseFor(token),
        .kw_while => self.parseWhile(token),
        .kw_break => self.parseBreak(token),
        .kw_continue => self.parseContinue(token),
        .kw_return => blk: {
            const value = try self.parseOptionalValue();
            const span = if (value) |v| Span.merge(token.span(), v.span) else token.span();
            break :blk try self.allocCst(span, .{ .return_expr = .{ .kw_tok = token, .value = value } });
        },
        .kw_comp => self.parseComp(token),
        .kw_import => self.parseImport(token),
        .kw_spawn => self.parseUnary(.spawn, 60, token),
        .kw_yield => self.allocCst(token.span(), .{ .yield = .{ .tok = token } }),
        .lsquiggly => self.parseTable(token),
        .kw_type => {
            if (self.check(.ident)) return self.parseDecl(token);
            return self.allocCst(token.span(), .{ .ident = .{ .tok = token } });
        },
        .kw_pub => self.parsePubPrefix(),
        .eof => return error.UnexpectedToken,
        .colon => blk: {
            try self.recordError(
                .UnexpectedToken,
                "':' without a following name is not a value; use ':name' for an atom",
                token.span(),
            );

            break :blk self.allocCst(token.span(), .{ .err = .{ .toks = try self.dupeToks(&.{token}) } });
        },
        .attribute => self.parseAttrs(token),
        else => return error.UnexpectedToken,
    };
}

/// dupe a token slice for `err` nodes
fn dupeToks(self: *Parser, toks: []const Token) std.mem.Allocator.Error![]Token {
    return self.alloc.dupe(Token, toks);
}

/// -, not
fn parseUnary(self: *Parser, op: cst.UnaryOp, right_bp: u8, token: Token) anyerror!*CstNode {
    const expr = try self.parseExpression(right_bp);
    return self.allocCst(Span.merge(token.span(), expr.span), .{ .unary = .{ .op_tok = token, .op = op, .expr = expr } });
}

/// true when next token cannot start a value; `return`/`break` carry nil
fn atValueEnd(self: *Parser) bool {
    return switch (self.peek().type) {
        .eof, .kw_end, .kw_else, .semicolon, .comma, .bar, .rparen, .rbracket, .rsquiggly => true,
        else => false,
    };
}

/// optional `return`/`break` operand; null when absent
fn parseOptionalValue(self: *Parser) anyerror!?*CstNode {
    if (self.atValueEnd()) return null;
    return self.parseExpression(0);
}

const AttrKind = enum { native };

const attr_table = std.StaticStringMap(AttrKind).initComptime(.{
    .{ "@native", .native },
});

const PendingAttr = struct {
    kind: AttrKind,
    tok: Token,
};

fn parseAttrs(self: *Parser, first: Token) anyerror!*CstNode {
    var pending: std.ArrayList(PendingAttr) = .empty;
    defer pending.deinit(self.alloc);

    var token = first;
    while (true) {
        const kind = attr_table.get(token.text) orelse return error.UnknownAttribute;
        try pending.append(self.alloc, .{ .kind = kind, .tok = token });

        if (!self.check(.attribute)) break;
        token = self.advance();
    }

    const target = try self.parsePrefix();
    const toks = try self.alloc.alloc(Token, pending.items.len);
    for (pending.items, toks) |attr, *dst| dst.* = attr.tok;
    // toks stay outermost for source order; lowering lands native on the fn
    target.attrs = toks;
    try validateAttrTarget(target);
    return target;
}

/// same rejections as before; lowering applies blindly to the validated shape
fn validateAttrTarget(node: *CstNode) anyerror!void {
    switch (node.kind) {
        .decl => return validateAttrTarget(node.kind.decl.inner),
        .fn_def, .fn_method => return,
        .binding => |b| {
            if (b.value.kind != .fn_def) return error.UnexpectedToken;
            return validateAttrTarget(b.value);
        },
        .assign => |a| {
            if (a.value.kind != .fn_def) return error.UnexpectedToken;
            return validateAttrTarget(a.value);
        },
        else => return error.UnexpectedToken,
    }
}

fn parseDocAttr(self: *Parser, doc_token: Token) anyerror!*CstNode {
    const target = try self.parsePrefix();
    try checkDocTarget(target);
    // doc outermost for src arder, lowering routes to fn
    // target is fresh from this parse, attach at constructiontime
    cst.attachDoc(target, doc_token);
    return target;
}

/// doc lands on decls or method defs, like before
fn checkDocTarget(node: *CstNode) anyerror!void {
    switch (node.kind) {
        .decl, .fn_method => return,
        .assign => |a| {
            if (a.value.kind != .fn_def) return error.UnexpectedToken;
            return;
        },
        else => return error.UnexpectedToken,
    }
}

/// fn forms: anon, named, and `obj:name`/`obj.field` with implicit self
fn parseFnWithBodyMin(self: *Parser, start: Token, body_min_bp: u8) anyerror!*CstNode {
    // named fn def?
    if (self.check(.ident)) {
        const first_ident = self.advance();

        // `fn obj:method(params) body` with implicit self
        if (self.peek().type == .atom) {
            const atom_token = self.advance();
            const lparen_tok = try self.expect(.lparen);
            const params = try self.parseParamList(.rparen);
            const rparen_tok = try self.expect(.rparen);
            const arrow_tok: ?Token = if (self.match(.arrow)) self.prevToken() else null;
            const return_type = if (arrow_tok != null) try self.parseTypeExpr() else null;
            const body = try self.parseStatementExpression(body_min_bp);

            return self.allocCst(Span.merge(start.span(), body.span), .{
                .fn_method = .{
                    .fn_tok = start,
                    .head = .{ .method_colon = .{ .obj_tok = first_ident, .atom_tok = atom_token } },
                    .lt_tok = null,
                    .type_params = &.{},
                    .tp_commas = &.{},
                    .gt_tok = null,
                    .lparen_tok = lparen_tok,
                    .params = params.params,
                    .commas = params.commas,
                    .rparen_tok = rparen_tok,
                    .arrow_tok = arrow_tok,
                    .return_type = return_type,
                    .body = body,
                },
            });
        }

        // `fn obj.field(params) body`
        if (self.match(.dot)) {
            const dot_tok = self.prevToken();
            const field_name = try self.expectName();
            const lparen_tok = try self.expect(.lparen);
            const params = try self.parseParamList(.rparen);
            const rparen_tok = try self.expect(.rparen);
            const arrow_tok: ?Token = if (self.match(.arrow)) self.prevToken() else null;
            const return_type = if (arrow_tok != null) try self.parseTypeExpr() else null;
            const body = try self.parseStatementExpression(body_min_bp);

            return self.allocCst(Span.merge(start.span(), body.span), .{
                .fn_method = .{
                    .fn_tok = start,
                    .head = .{ .method_dot = .{ .obj_tok = first_ident, .dot_tok = dot_tok, .name_tok = field_name } },
                    .lt_tok = null,
                    .type_params = &.{},
                    .tp_commas = &.{},
                    .gt_tok = null,
                    .lparen_tok = lparen_tok,
                    .params = params.params,
                    .commas = params.commas,
                    .rparen_tok = rparen_tok,
                    .arrow_tok = arrow_tok,
                    .return_type = return_type,
                    .body = body,
                },
            });
        }

        var lt_tok: ?Token = null;
        var tps: []Token = &.{};
        var tp_commas: []Token = &.{};
        var gt_tok: ?Token = null;
        if (self.check(.lt)) {
            lt_tok = self.advance();
            const list = try self.parseTypeParamList();
            tps = list.tps;
            tp_commas = list.commas;
            gt_tok = list.gt_tok;
        }

        if (self.check(.lparen)) {
            const lparen_tok = try self.expect(.lparen);
            const params = try self.parseParamList(.rparen);
            const rparen_tok = try self.expect(.rparen);
            const arrow_tok: ?Token = if (self.match(.arrow)) self.prevToken() else null;
            const return_type = if (arrow_tok != null) try self.parseTypeExpr() else null;
            const body = try self.parseStatementExpression(body_min_bp);

            const kind: cst.DeclKind = if (self.bindingScope()) .global_const else .@"const";
            const target = try self.allocCst(first_ident.span(), .{ .ident = .{ .tok = first_ident } });
            const bind = try self.allocCst(Span.merge(start.span(), body.span), .{
                .binding = .{
                    // `fn` keyword sorts first, so the binding owns it here
                    .kind_tok = start,
                    .kind = kind,
                    .target = target,
                    .colon_tok = null,
                    .type = null,
                    .eq_tok = null,
                    .value = try self.allocCst(Span.merge(start.span(), body.span), .{
                        .fn_def = .{
                            .fn_tok = null,
                            .head = .{ .named = .{ .name = first_ident.text, .name_span = first_ident.span() } },
                            .kind = kind,
                            .lt_tok = lt_tok,
                            .type_params = tps,
                            .tp_commas = tp_commas,
                            .gt_tok = gt_tok,
                            .lparen_tok = lparen_tok,
                            .params = params.params,
                            .commas = params.commas,
                            .rparen_tok = rparen_tok,
                            .arrow_tok = arrow_tok,
                            .return_type = return_type,
                            .body = body,
                        },
                    }),
                },
            });
            return self.allocCst(
                Span.merge(start.span(), body.span),
                .{ .decl = .{ .pub_tok = null, .kind = kind, .inner = bind } },
            );
        }
        return error.UnexpectedToken;
    }

    // anon `fn(params) body`
    const lparen_tok = try self.expect(.lparen);
    const params = try self.parseParamList(.rparen);
    const rparen_tok = try self.expect(.rparen);
    const arrow_tok: ?Token = if (self.match(.arrow)) self.prevToken() else null;
    const return_type = if (arrow_tok != null) try self.parseTypeExpr() else null;
    const body = try self.parseStatementExpression(body_min_bp);
    return self.allocCst(Span.merge(start.span(), body.span), .{
        .fn_def = .{
            .fn_tok = start,
            .head = .anon,
            .kind = .@"const",
            .lt_tok = null,
            .type_params = &.{},
            .tp_commas = &.{},
            .gt_tok = null,
            .lparen_tok = lparen_tok,
            .params = params.params,
            .commas = params.commas,
            .rparen_tok = rparen_tok,
            .arrow_tok = arrow_tok,
            .return_type = return_type,
            .body = body,
        },
    });
}

fn parseComp(self: *Parser, token: Token) anyerror!*CstNode {
    const expr = try self.parseExpression(BP.comp);
    return self.allocCst(Span.merge(token.span(), expr.span), .{
        .comp_block = .{ .kw_tok = token, .expr = expr },
    });
}

/// `if`/`unless` with optional `else`
fn parseConditional(self: *Parser, start: Token, comptime is_unless: bool) anyerror!*CstNode {
    const condition = try self.parseScoped(.kw_else, self.allow_bare_calls, 0);
    const then_expr = try self.parseExpression(0);
    const else_tok: ?Token = if (self.match(.kw_else)) self.prevToken() else null;
    const else_expr = if (else_tok != null) try self.parseExpression(0) else null;
    const end_span = if (else_expr) |branch| branch.span else then_expr.span;
    return self.allocCst(Span.merge(start.span(), end_span), .{
        .if_expr = .{
            .kw_tok = start,
            .unless = is_unless,
            .cond = condition,
            .then = then_expr,
            .else_tok = else_tok,
            .else_ = else_expr,
        },
    });
}

/// `match` with `|` arms
fn parseMatch(self: *Parser, start: Token) anyerror!*CstNode {
    const subject: ?*CstNode = blk: {
        if (self.check(.bar)) break :blk null;
        break :blk try self.parseExpression(25);
    };

    var arms = try std.ArrayList(cst.CstArm).initCapacity(self.alloc, 2);
    errdefer {
        for (arms.items) |arm| self.alloc.free(arm.matchers);
        arms.deinit(self.alloc);
    }

    var end_span = if (subject) |s| s.span else start.span();
    var bars = try std.ArrayList(Token).initCapacity(self.alloc, 2);
    errdefer bars.deinit(self.alloc);
    while (self.match(.bar)) {
        try bars.append(self.alloc, self.prevToken());
        const arm = try self.parseMatchArm();
        end_span = arm.then.span;
        try arms.append(self.alloc, arm);
    }

    if (arms.items.len == 0) return error.ExpectedMatchArm;

    return self.allocCst(Span.merge(start.span(), end_span), .{
        .match = .{
            .kw_tok = start,
            .subject = subject,
            .bars = try bars.toOwnedSlice(self.alloc),
            .arms = try arms.toOwnedSlice(self.alloc),
        },
    });
}

/// `pat [when expr] => expr`
fn parseMatchArm(self: *Parser) anyerror!cst.CstArm {
    var matchers = try std.ArrayList(cst.CstMatcher).initCapacity(self.alloc, 2);
    errdefer matchers.deinit(self.alloc);
    var commas = try std.ArrayList(Token).initCapacity(self.alloc, 2);
    errdefer commas.deinit(self.alloc);

    while (true) {
        if (self.checkIdentText("_")) {
            const wild = self.advance();
            try matchers.append(self.alloc, .{ .wildcard = wild });
        } else {
            var m = try self.parseScoped(null, false, 25);
            if (self.check(.colon)) {
                const colon_tok = try self.expect(.colon);
                const type_name = try self.parseTypeExpr();
                m = try self.allocCst(Span.merge(m.span, type_name.span), .{
                    .ascribed = .{ .expr = m, .colon_tok = colon_tok, .type = type_name },
                });
            }

            try matchers.append(self.alloc, .{ .expr = m });
        }
        if (!self.match(.comma)) break;
        try commas.append(self.alloc, self.prevToken());
    }

    var when_tok: ?Token = null;
    var guard: ?*CstNode = null;
    if (self.match(.kw_when)) {
        when_tok = self.prevToken();
        guard = try self.parseScoped(null, false, 25);
    }
    const arrow_tok = try self.expect(.fat_arrow);

    return .{
        .matchers = try matchers.toOwnedSlice(self.alloc),
        .commas = try commas.toOwnedSlice(self.alloc),
        .when_tok = when_tok,
        .guard = guard,
        .arrow_tok = arrow_tok,
        .then = try self.parseExpression(0),
    };
}

/// `type Name = TypeExpr`
fn parseTypeExpr(self: *Parser) anyerror!*cst.CstType {
    if (self.lexer != null) {
        return try type_syntax.parseCstTypeExprFromStream(self, self.alloc);
    }
    return try type_syntax.parseCstTypeExpr(self.tokens, &self.pos, self.alloc);
}

/// `const`/`let` binding with `{...}` destructuring
fn parseBinding(self: *Parser, comptime kind_in: cst.DeclKind, start: Token) anyerror!*CstNode {
    const kind: cst.DeclKind = if (self.bindingScope())
        (if (kind_in == .@"const") .global_const else .global)
    else
        kind_in;

    const target: *CstNode = blk: {
        if (self.check(.lsquiggly)) {
            // keyless tables destructure in lowering; keyed stay values and fail later
            break :blk try self.parseTable(self.advance());
        } else {
            const first = try self.expectIdent();
            if (self.match(.comma)) {
                try self.recordError(
                    .UnexpectedToken,
                    "use `{...}` for destructuring",
                    self.peek().span(),
                );
                return error.UnexpectedToken;
            } else {
                break :blk try self.allocCst(first.span(), .{ .ident = .{ .tok = first } });
            }
        }
    };

    var colon_tok: ?Token = null;
    var type_name: ?*cst.CstType = null;
    if (self.match(.colon)) {
        colon_tok = self.prevToken();
        type_name = try self.parseTypeExpr();
    }
    const eq_tok = try self.expect(.assign);
    const value = try self.parseStatementExpression(0);

    const span = Span.merge(start.span(), value.span);
    const binding = try self.allocCst(span, .{
        .binding = .{
            .kind_tok = start,
            .kind = kind,
            .target = target,
            .colon_tok = colon_tok,
            .type = type_name,
            .eq_tok = eq_tok,
            .value = value,
        },
    });

    return self.allocCst(span, .{ .decl = .{ .pub_tok = null, .kind = kind, .inner = binding } });
}

fn parseDecl(self: *Parser, start: Token) anyerror!*CstNode {
    return switch (start.type) {
        .kw_const => {
            return try self.parseBinding(.@"const", start);
        },
        .kw_let => {
            return try self.parseBinding(.let, start);
        },
        .kw_global => {
            return try self.parseBinding(.global, start);
        },
        .kw_fn => {
            return try self.parseFnWithBodyMin(start, 0);
        },
        .kw_test => blk: {
            var slash_tok: ?Token = null;
            var skip_tok: ?Token = null;
            if (self.match(.slash)) {
                slash_tok = self.prevToken();
                if (self.checkIdentText("skip")) {
                    skip_tok = self.advance();
                } else return error.UnexpectedToken;
            }
            const name = try self.expectStringLiteral();
            const body_start = try self.expect(.kw_do);
            const body = try self.parseBlock(body_start);
            const node = try self.allocCst(Span.merge(start.span(), body.span), .{
                .test_block = .{
                    .kw_tok = start,
                    .slash_tok = slash_tok,
                    .skip_tok = skip_tok,
                    .name = name,
                    .body = body,
                },
            });
            break :blk self.allocCst(start.span(), .{
                .decl = .{ .pub_tok = null, .kind = cst.DeclKind.test_decl, .inner = node },
            });
        },
        .kw_suite => blk: {
            const name = try self.expectStringLiteral();
            const body_start = try self.expect(.kw_do);
            const body = try self.parseBlock(body_start);
            const node = try self.allocCst(Span.merge(start.span(), body.span), .{
                .test_suite = .{ .kw_tok = start, .name = name, .body = body },
            });
            break :blk self.allocCst(start.span(), .{
                .decl = .{ .pub_tok = null, .kind = cst.DeclKind.suite_decl, .inner = node },
            });
        },
        .kw_type => blk: {
            if (!self.check(.ident)) return error.UnexpectedToken;
            const first = try self.expectIdent();
            break :blk self.parseTypeAliasDecl(start, first, .type_alias_decl, false);
        },
        .kw_declare => blk: {
            // `type` and `import` are baselib globals, usable as names
            if (!self.check(.ident)) switch (self.peek().type) {
                .kw_type, .kw_import => {},
                else => return error.UnexpectedToken,
            };
            const first = self.advance();
            // declares are pub by default
            break :blk self.parseTypeAliasDecl(start, first, .declare_decl, true);
        },
        else => return error.UnexpectedToken,
    };
}

/// shared tail of `type` and `declare` alias decls
fn parseTypeAliasDecl(
    self: *Parser,
    start: Token,
    first: Token,
    kind: cst.DeclKind,
    pub_: bool,
) anyerror!*CstNode {
    const hh = try self.parseDeclareHead(first);

    const eq_tok = try self.expect(.assign);
    const type_expr = try self.parseTypeExpr();

    const node = try self.allocCst(Span.merge(start.span(), type_expr.span), .{
        .type_alias = .{
            .kw_tok = start,
            .segs = hh.segs,
            .dots = hh.dots,
            .lt_tok = hh.lt_tok,
            .tps = hh.tps,
            .tp_commas = hh.tp_commas,
            .gt_tok = hh.gt_tok,
            .eq_tok = eq_tok,
            .type = type_expr,
        },
    });
    return self.allocCst(
        start.span(),
        .{ .decl = .{ .pub_tok = null, .kind = kind, .inner = node, .pub_ = pub_ } },
    );
}

/// shared dotted head for `declare` and `type`
/// , segs always starts with the name; dotted iff longer
fn parseDeclareHead(self: *Parser, first: Token) !cst.DeclareHead {
    var dots = std.ArrayList(Token).empty;
    var segs = std.ArrayList(Token).empty;
    // name always leads so tooling finds it in one place
    try segs.append(self.alloc, first);
    while (self.match(.dot)) {
        try dots.append(self.alloc, self.prevToken());
        const seg = try self.expectName();
        try segs.append(self.alloc, seg);
    }
    var lt_tok: ?Token = null;
    var tps: []Token = &.{};
    var tp_commas: []Token = &.{};
    var gt_tok: ?Token = null;
    if (self.check(.lt)) {
        lt_tok = self.advance();
        const list = try self.parseTypeParamList();
        tps = list.tps;
        tp_commas = list.commas;
        gt_tok = list.gt_tok;
    }
    return .{
        .dots = try dots.toOwnedSlice(self.alloc),
        .segs = try segs.toOwnedSlice(self.alloc),
        .lt_tok = lt_tok,
        .tps = tps,
        .tp_commas = tp_commas,
        .gt_tok = gt_tok,
    };
}

/// optional `/label` with its tokens; rewinds when not hugging
fn parseOptionalLabel(self: *Parser) struct { label: ?[]const u8, slash_tok: ?Token, label_tok: ?Token } {
    if (self.match(.slash)) {
        const slash_tok = self.prevToken();
        if (!self.tokenAdjacent(self.prevToken().span().end)) {
            self.pos -= 1;
            return .{ .label = null, .slash_tok = null, .label_tok = null };
        }
        const ident = self.expectIdent() catch {
            self.pos -= 1;
            return .{ .label = null, .slash_tok = null, .label_tok = null };
        };
        return .{ .label = ident.text, .slash_tok = slash_tok, .label_tok = ident };
    }
    return .{ .label = null, .slash_tok = null, .label_tok = null };
}

/// `loop do expr end`
fn parseLoop(self: *Parser, start: Token) anyerror!*CstNode {
    const label = self.parseOptionalLabel();
    const body = try self.parseExpression(0);
    return self.allocCst(
        Span.merge(start.span(), body.span),
        .{ .loop_expr = .{ .kw_tok = start, .slash_tok = label.slash_tok, .label_tok = label.label_tok, .body = body } },
    );
}

/// `while cond expr`
fn parseWhile(self: *Parser, start: Token) anyerror!*CstNode {
    const label = self.parseOptionalLabel();
    const predicate = try self.parseExpression(25);
    const body = try self.parseExpression(0);
    return self.allocCst(Span.merge(start.span(), body.span), .{
        .while_loop = .{
            .kw_tok = start,
            .slash_tok = label.slash_tok,
            .label_tok = label.label_tok,
            .pred = predicate,
            .body = body,
        },
    });
}

fn parseFor(self: *Parser, start: Token) anyerror!*CstNode {
    const label = self.parseOptionalLabel();
    var params = try std.ArrayList(Token).initCapacity(self.alloc, 2);
    errdefer params.deinit(self.alloc);
    var commas = try std.ArrayList(Token).initCapacity(self.alloc, 2);
    errdefer commas.deinit(self.alloc);
    const first = try self.expectIdent();
    try params.append(self.alloc, first);
    while (self.match(.comma)) {
        try commas.append(self.alloc, self.prevToken());
        const name = try self.expectIdent();
        try params.append(self.alloc, name);
    }
    const in_tok = try self.expect(.kw_in);

    const iter = try self.parseForRange();
    const body = try self.parseExpression(0);
    return self.allocCst(Span.merge(start.span(), body.span), .{
        .for_loop = .{
            .for_tok = start,
            .slash_tok = label.slash_tok,
            .label_tok = label.label_tok,
            .params = try params.toOwnedSlice(self.alloc),
            .commas = try commas.toOwnedSlice(self.alloc),
            .in_tok = in_tok,
            .iter = iter,
            .body = body,
        },
    });
}

/// range expr in `for`; missing end is +/-inf
/// , covers `..5`, `0..`, `0..5`, `0..2..10`
fn parseForRange(self: *Parser) anyerror!*CstNode {
    if (self.check(.dotdot)) {
        const dot1_tok = self.advance();
        return self.parseForRangeEnd(null, dot1_tok.span().end, dot1_tok);
    }

    const first = try self.parseStoppingAtDotDot(0);

    if (!self.match(.dotdot)) return first;

    const dot1_tok = self.prevToken();
    if (dot1_tok.span().start != first.span.end) {
        try self.recordError(.UnexpectedToken, "`..` must be adjacent to the range start", self.peek().span());
        return error.UnexpectedToken;
    }

    return self.parseForRangeEnd(first, dot1_tok.span().end, dot1_tok);
}

fn parseForRangeEnd(self: *Parser, start: ?*CstNode, dotdot_end: usize, dot1_tok: Token) anyerror!*CstNode {
    const span_start = if (start) |s| s.span else dot1_tok.span();
    if (!self.tokenAdjacent(dotdot_end)) {
        const node = try self.allocCst(
            Span.merge(span_start, self.peek().span()),
            .{ .for_range = .{ .start = start, .dot1_tok = dot1_tok, .mid = null, .dot2_tok = null, .end = null } },
        );
        return node;
    }

    const mid = try self.parseStoppingAtDotDot(0);

    if (self.match(.dotdot)) {
        const dot2_tok = self.prevToken();
        if (dot2_tok.span().start != mid.span.end) {
            try self.recordError(.UnexpectedToken, "`..` must be adjacent to the step", self.peek().span());
            return error.UnexpectedToken;
        }
        const second_dd_end = dot2_tok.span().end;
        if (!self.tokenAdjacent(second_dd_end)) {
            return self.allocCst(
                Span.merge(span_start, mid.span),
                .{ .for_range = .{ .start = start, .dot1_tok = dot1_tok, .mid = mid, .dot2_tok = dot2_tok, .end = null } },
            );
        }
        const end = try self.parseExpression(0);
        return self.allocCst(
            Span.merge(span_start, end.span),
            .{ .for_range = .{ .start = start, .dot1_tok = dot1_tok, .mid = mid, .dot2_tok = dot2_tok, .end = end } },
        );
    }

    return self.allocCst(
        Span.merge(span_start, mid.span),
        .{ .for_range = .{ .start = start, .dot1_tok = dot1_tok, .mid = mid, .dot2_tok = null, .end = null } },
    );
}

/// true when next token hugs given position; no whitespace gap
/// , past-the-end peeks clamp to eof so no length guard needed
fn tokenAdjacent(self: *Parser, prev_end: usize) bool {
    return self.peek().span().start == prev_end;
}

fn parseBreak(self: *Parser, start: Token) anyerror!*CstNode {
    const label = self.parseOptionalLabel();
    const value = try self.parseOptionalValue();
    const span = if (value) |v| Span.merge(start.span(), v.span) else start.span();
    return self.allocCst(span, .{
        .break_expr = .{ .kw_tok = start, .slash_tok = label.slash_tok, .label_tok = label.label_tok, .value = value },
    });
}

fn parseContinue(self: *Parser, start: Token) anyerror!*CstNode {
    const label = self.parseOptionalLabel();
    return self.allocCst(start.span(), .{
        .continue_expr = .{ .kw_tok = start, .slash_tok = label.slash_tok, .label_tok = label.label_tok },
    });
}

/// `pub` prefix on decls
/// , `pub` itself was already consumed by parsePrefix: it is prevToken,
/// , peek would grab the following keyword and orphan pub's trivia
fn parsePubPrefix(self: *Parser) anyerror!*CstNode {
    const pub_tok = self.prevToken();
    const pub_keywords = comptime [_]TokenType{
        .kw_const,
        .kw_let,
        .kw_fn,
        .kw_test,
        .kw_suite,
        .kw_type,
        .kw_import,
        .kw_declare,
    };
    var found = false;
    inline for (pub_keywords) |kt| {
        if (self.check(kt)) {
            found = true;
            break;
        }
    }
    if (!found) return error.UnexpectedToken;
    const decl_start = self.advance();

    // todo: import is no decl node
    if (decl_start.type == .kw_import) {
        const node = try self.parseImport(decl_start);
        // fresh node
        // constructiontime attach (no pub_tok slot on imports)
        if (node.kind == .import) node.kind.import.pub_ = true;
        return node;
    }

    const node = try self.parseDecl(decl_start);
    // fresh node
    // constructiontime attach (decl always wraps here)
    if (node.kind == .decl) cst.attachDeclPub(node, pub_tok);
    return node;
}

/// `import "path"` or `import { ... }`
fn parseImport(self: *Parser, start: Token) anyerror!*CstNode {
    // table form `{ m1 = "mod1", "mod2" }`
    if (self.peek().type == .lsquiggly) {
        const lbrace_tok = try self.expect(.lsquiggly);
        var items = try std.ArrayList(cst.CstImportItem).initCapacity(self.alloc, 4);
        errdefer items.deinit(self.alloc);
        var commas = try std.ArrayList(Token).initCapacity(self.alloc, 4);
        errdefer commas.deinit(self.alloc);

        while (self.peek().type != .rsquiggly) {
            const pt = self.peek().type;
            if (pt == .string or pt == .string_start or pt == .ml_string_start) {
                // `"path"` auto-binds
                const path_token = try self.expectStringLiteral();
                try items.append(self.alloc, .{
                    .name_tok = null,
                    .eq_tok = null,
                    .path = path_token,
                    .span = Span.merge(start.span(), path_token.span),
                });
            } else {
                // `ident = "path"` with custom name
                const name_token = try self.expect(.ident);
                const eq_tok = try self.expect(.assign);
                const path_token = try self.expectStringLiteral();
                try items.append(self.alloc, .{
                    .name_tok = name_token,
                    .eq_tok = eq_tok,
                    .path = path_token,
                    .span = Span.merge(start.span(), path_token.span),
                });
            }
            if (self.peek().type != .rsquiggly) {
                _ = try self.expect(.comma);
                try commas.append(self.alloc, self.prevToken());
            }
        }
        const rbrace_tok = try self.expect(.rsquiggly);

        return self.allocCst(start.span(), .{
            .import = .{
                .import_tok = start,
                .lbrace_tok = lbrace_tok,
                .items = try items.toOwnedSlice(self.alloc),
                .commas = try commas.toOwnedSlice(self.alloc),
                .rbrace_tok = rbrace_tok,
                .pub_ = false,
            },
        });
    }

    // autobind `import "path"`
    {
        const path_token = try self.expectStringLiteral();
        var items = try std.ArrayList(cst.CstImportItem).initCapacity(self.alloc, 1);
        errdefer items.deinit(self.alloc);
        try items.append(self.alloc, .{
            .name_tok = null,
            .eq_tok = null,
            .path = path_token,
            .span = Span.merge(start.span(), path_token.span),
        });
        return self.allocCst(Span.merge(start.span(), path_token.span), .{
            .import = .{
                .import_tok = start,
                .lbrace_tok = null,
                .items = try items.toOwnedSlice(self.alloc),
                .commas = &.{},
                .rbrace_tok = null,
                .pub_ = false,
            },
        });
    }
}

/// `do expr end`
fn parseBlock(self: *Parser, start: Token) anyerror!*CstNode {
    if (self.match(.slash)) {
        const slash_tok = self.prevToken();
        const ident = try self.expectIdent();
        const body = try self.parseDoBody();
        // end excluded when stmts exist, like the old span mutation
        const span = if (body.stmts.len == 0)
            Span.merge(start.span(), body.end_tok.span())
        else
            Span.merge(start.span(), body.stmts[body.stmts.len - 1].span);
        return self.allocCst(span, .{
            .do_block = .{
                .do_tok = start,
                .slash_tok = slash_tok,
                .label_tok = ident,
                .stmts = body.stmts,
                .semis = body.semis,
                .end_tok = body.end_tok,
            },
        });
    }
    const body = try self.parseDoBody();
    const span = if (body.stmts.len == 0)
        Span.merge(start.span(), body.end_tok.span())
    else
        Span.merge(start.span(), body.stmts[body.stmts.len - 1].span);
    return self.allocCst(span, .{
        .do_block = .{
            .do_tok = start,
            .slash_tok = null,
            .label_tok = null,
            .stmts = body.stmts,
            .semis = body.semis,
            .end_tok = body.end_tok,
        },
    });
}

/// `{ key = value, [expr] = value, value, ... }`
fn parseTable(self: *Parser, start: Token) anyerror!*CstNode {
    var entries = try std.ArrayList(cst.CstEntry).initCapacity(self.alloc, 4);
    errdefer entries.deinit(self.alloc);
    var commas = try std.ArrayList(Token).initCapacity(self.alloc, 4);
    errdefer commas.deinit(self.alloc);
    var end_span = start.span();

    while (!self.check(.rsquiggly)) {
        if (self.match(.lbracket)) {
            const lbracket_tok = self.prevToken();
            const computed_key = try self.parseExpression(0);
            const rbracket_tok = try self.expect(.rbracket);
            const eq_tok = try self.expect(.assign);
            const keyed_value = try self.parseExpression(0);
            end_span = keyed_value.span;
            try entries.append(self.alloc, .{ .computed = .{
                .lbracket_tok = lbracket_tok,
                .key = computed_key,
                .rbracket_tok = rbracket_tok,
                .eq_tok = eq_tok,
                .value = keyed_value,
            } });
            if (!self.match(.comma)) break;
            try commas.append(self.alloc, self.prevToken());
            continue;
        }

        const first = try self.parseExpression(6);
        if (self.match(.assign)) {
            const eq_tok = self.prevToken();
            const keyed_value = try self.parseExpression(0);
            end_span = keyed_value.span;
            try entries.append(self.alloc, .{ .keyed = .{ .key = first, .eq_tok = eq_tok, .value = keyed_value } });
        } else if (self.check(.colon)) {
            const colon_tok = try self.expect(.colon);
            const type_name = try self.parseTypeExpr();
            const asc_span = Span.merge(first.span, type_name.span);
            const asc = try self.allocCst(asc_span, .{
                .ascribed = .{ .expr = first, .colon_tok = colon_tok, .type = type_name },
            });
            end_span = asc.span;

            try entries.append(self.alloc, .{ .bare = .{ .value = asc } });
        } else {
            end_span = first.span;
            try entries.append(self.alloc, .{ .bare = .{ .value = first } });
        }

        if (!self.match(.comma)) break;
        try commas.append(self.alloc, self.prevToken());
    }

    const close = try self.expect(.rsquiggly);
    return self.allocCst(
        Span.merge(start.span(), if (entries.items.len == 0) close.span() else end_span),
        .{ .table = .{
            .lbrace_tok = start,
            .entries = try entries.toOwnedSlice(self.alloc),
            .commas = try commas.toOwnedSlice(self.alloc),
            .rbrace_tok = close,
        } },
    );
}

test "compiled table equals-key entries" {
    try testing_helpers.topNumber("{ a = 5 }[:a]", 5);
    try testing_helpers.topNumber("{ 7 = 10 }[7]", 10);
    try testing_helpers.topNumber("{ \"a\" = 5 }[\"a\"]", 5);
    try testing_helpers.topNumber("let t = { 1 } t[1] = 5 len(t)", 2);
}

test "compiled table square bracket special case" {
    try testing_helpers.topNumber("let k = \"asdf\" { [k] = 5 }[\"asdf\"]", 5);
}

test "parser table square bracket parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try testing.parseOne(arena.allocator(), "{ [a] = 5, \"b\" = 6, c = 7 }");
    try std.testing.expect(root.kind == .table);
    const entries = root.kind.table.entries;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(entries[0] == .computed);
    try std.testing.expect(entries[1] == .keyed);
    try std.testing.expect(entries[2] == .keyed);
    try std.testing.expectEqualStrings("a", entries[0].computed.key.kind.ident.tok.text);
}

test "parser test block parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try testing.parseOne(arena.allocator(), "test \"smoke\" do ok! end");
    try std.testing.expect(root.kind == .decl);
    try std.testing.expect(root.kind.decl.kind == .test_decl);
    const tb = root.kind.decl.inner.kind.test_block;
    try std.testing.expectEqualStrings("smoke", tb.name.text);
}

/// `(expr)` or `()`; `()` is nil
fn parseParenExpr(self: *Parser, start: Token) anyerror!*CstNode {
    if (self.match(.rparen)) {
        const close = self.prevToken();
        return self.allocCst(
            Span.merge(start.span(), close.span()),
            .{ .paren = .{ .lparen_tok = start, .expr = null, .rparen_tok = close } },
        );
    }

    const first = try self.parseExpression(0);
    if (!self.match(.comma)) {
        const close = try self.expect(.rparen);
        return self.allocCst(
            Span.merge(start.span(), close.span()),
            .{ .paren = .{ .lparen_tok = start, .expr = first, .rparen_tok = close } },
        );
    }

    try self.recordError(
        .UnexpectedToken,
        "unexpected `,` in parens, use `{...}` for tables",
        self.peek().span(),
    );
    return error.UnexpectedToken;
}

fn isBareCallArgToken(t: TokenType) bool {
    return bare_call_arg_start_tokens.get(t);
}

/// true when expr allows bare call after it
fn isBareCallArgumentStart(self: *Parser, callee: *CstNode) bool {
    if (!cstExprAllowsBareCall(callee)) return false;
    if (self.stop_on_stmt_start and self.peek().nl_before) return false;
    return isBareCallArgToken(self.peek().type);
}

/// one literal argument for a bare call; postfix operators stay outside
fn parseBareCallArg(self: *Parser) anyerror!*CstNode {
    if (!isBareCallArgToken(self.peek().type)) {
        try self.recordError(
            .UnexpectedToken,
            "bare call argument must be a string or table literal",
            self.peek().span(),
        );
        return error.UnexpectedToken;
    }
    return self.parsePrefix();
}

/// `<T>` followed by a bare literal instead of `(args)`
fn isGenericBareArgAhead(self: *Parser) bool {
    if (self.peek().type != .lt) return false;
    var i: usize = 1;
    var budget: usize = max_generic_lookahead_tokens;

    while (budget > 0) {
        budget -= 1;
        switch (self.peekAt(i).type) {
            .ident, .kw_type, .kw_import => i += 1,
            .comma => i += 1,
            .gt => {
                const arg = self.peekAt(i + 1);
                return !arg.nl_before and isBareCallArgToken(arg.type);
            },
            else => return false,
        }
    }
    return false;
}

/// `name`, `name: type`
fn parseParamList(self: *Parser, terminator: TokenType) anyerror!cst.ParamList {
    var params = try std.ArrayList(cst.CstParam).initCapacity(self.alloc, 4);
    errdefer params.deinit(self.alloc);
    var commas = try std.ArrayList(Token).initCapacity(self.alloc, 4);
    errdefer commas.deinit(self.alloc);

    while (!self.check(terminator)) {
        const qmark_tok: ?Token = if (self.match(.huh)) self.prevToken() else null;
        const name = try self.expectIdent();
        var param: cst.CstParam = .{ .name_tok = name, .qmark_tok = qmark_tok };

        if (self.match(.colon)) {
            param.colon_tok = self.prevToken();
            param.type = try self.parseTypeExpr();
        }
        if (self.match(.assign)) {
            param.eq_tok = self.prevToken();
            param.default = try self.parseExpression(0);
        }

        try params.append(self.alloc, param);
        if (!self.match(.comma)) break;
        try commas.append(self.alloc, self.prevToken());
    }

    return .{ .params = try params.toOwnedSlice(self.alloc), .commas = try commas.toOwnedSlice(self.alloc) };
}

/// `do ... end` body until `kw_end`
fn parseDoBody(self: *Parser) anyerror!struct { stmts: []*CstNode, semis: []Token, end_tok: Token } {
    self.scope_depth += 1;
    defer self.scope_depth -= 1;
    const list = try self.parseExprListUntil(.kw_end);
    const close = try self.expect(.kw_end);
    return .{ .stmts = list.stmts, .semis = list.semis, .end_tok = close };
}

/// parse with stop token and bare-call toggle
fn parseScoped(self: *Parser, stop: ?TokenType, allow_bare_calls: bool, min_bp: u8) anyerror!*CstNode {
    self.scope_depth += 1;
    defer self.scope_depth -= 1;
    const prev_stop = self.stop_token;
    const prev_allow_bare_calls = self.allow_bare_calls;
    self.stop_token = stop;
    self.allow_bare_calls = allow_bare_calls;
    defer {
        self.stop_token = prev_stop;
        self.allow_bare_calls = prev_allow_bare_calls;
    }
    return self.parseExpression(min_bp);
}

/// statement expr with stmt boundaries
fn parseStatementExpression(self: *Parser, min_bp: u8) anyerror!*CstNode {
    const prev_stop_on_stmt_start = self.stop_on_stmt_start;
    self.stop_on_stmt_start = true;
    defer self.stop_on_stmt_start = prev_stop_on_stmt_start;
    return self.parseExpression(min_bp);
}

/// exprs until terminator
/// , todo: defer goes here
fn parseExprListUntil(self: *Parser, terminator: TokenType) anyerror!cst.CstBlock {
    var stmts = try std.ArrayList(*CstNode).initCapacity(self.alloc, 4);
    errdefer stmts.deinit(self.alloc);
    var semis = try std.ArrayList(Token).initCapacity(self.alloc, 4);
    errdefer semis.deinit(self.alloc);

    while (!self.check(terminator) and !self.check(.eof)) {
        while (self.match(.semicolon)) try semis.append(self.alloc, self.prevToken());
        if (self.check(terminator) or self.check(.eof)) break;
        const expr = self.parseStatementExpression(0) catch |err| {
            if (syntaxInfo(err) == null) return err;
            try self.recordSyntaxError(err, self.peek());
            var skipped = std.ArrayList(Token).empty;
            self.syncToNextStatement(terminator, &skipped);
            if (skipped.items.len > 0) {
                const span = if (skipped.items.len == 1)
                    skipped.items[0].span()
                else
                    Span.merge(skipped.items[0].span(), skipped.items[skipped.items.len - 1].span());
                try stmts.append(self.alloc, try self.allocCst(span, .{
                    .err = .{ .toks = try skipped.toOwnedSlice(self.alloc) },
                }));
            } else skipped.deinit(self.alloc);
            continue;
        };
        try self.warnSpacedParen(expr);
        try stmts.append(self.alloc, expr);
    }

    return .{ .stmts = try stmts.toOwnedSlice(self.alloc), .semis = try semis.toOwnedSlice(self.alloc) };
}

/// `f (x)` at a statement boundary: warn and suggest `f; x`. Only statement
/// lists call this, so conditions/branches that legitimately start with `(`
/// are left alone.
fn warnSpacedParen(self: *Parser, expr: *const CstNode) !void {
    if (self.source.len == 0) return;
    const lparen = self.peek();
    if (lparen.type != .lparen or !lparen.space_before or lparen.nl_before) return;

    const expr_end = @min(expr.span.end, self.source.len);
    const lparen_start = @min(lparen.start, self.source.len);
    if (expr_end > lparen_start) return;
    for (self.source[expr_end..lparen_start]) |c| {
        if (c != ' ' and c != '\t') return;
    }

    const rparen_idx = self.matchingRparenIndex() orelse return;
    const rparen = self.peekAt(rparen_idx);
    const inner_start = @min(lparen.end, self.source.len);
    const inner_end = @min(rparen.start, self.source.len);
    if (inner_start > inner_end) return;

    const replacement = try self.alloc.print("{s}; {s}", .{
        self.source[@min(expr.span.start, self.source.len)..expr_end],
        self.source[inner_start..inner_end],
    });
    const span = Span{
        .start = expr.span.start,
        .end = rparen.end,
        .line = expr.span.line,
        .column = expr.span.column,
    };
    if (self.first_warn_code == null) self.first_warn_code = "space-before-call";
    try self.warnings.append(self.alloc, .{ .warn = "you probably don't want a space before `(`, it means it's not a call" });
    try self.warnings.append(self.alloc, .{ .span = .{ .span = span, .role = .primary, .message = "not a call" } });
    try self.warnings.append(self.alloc, .{ .suggestion = .{
        .span = span,
        .message = "separate them with `;`",
        .replacement = replacement,
    } });
}

fn matchingRparenIndex(self: *Parser) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        switch (self.peekAt(i).type) {
            .lparen => depth += 1,
            .rparen => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i;
            },
            .eof => return null,
            else => {},
        }
    }
}

/// comma-separated args until terminator
fn parseDelimitedExprList(self: *Parser, terminator: TokenType) anyerror!cst.CstList {
    var items = try std.ArrayList(*CstNode).initCapacity(self.alloc, 2);
    errdefer items.deinit(self.alloc);
    var commas = try std.ArrayList(Token).initCapacity(self.alloc, 2);
    errdefer commas.deinit(self.alloc);

    while (!self.check(terminator) and !self.check(.eof)) {
        const item = self.parseExpression(0) catch |err| {
            if (syntaxInfo(err) == null) return err;
            try self.recordSyntaxError(err, self.peek());
            var skipped = std.ArrayList(Token).empty;
            self.syncToNextStatement(terminator, &skipped);
            if (skipped.items.len > 0) {
                const span = if (skipped.items.len == 1)
                    skipped.items[0].span()
                else
                    Span.merge(skipped.items[0].span(), skipped.items[skipped.items.len - 1].span());
                try items.append(self.alloc, try self.allocCst(span, .{
                    .err = .{ .toks = try skipped.toOwnedSlice(self.alloc) },
                }));
            } else skipped.deinit(self.alloc);
            if (self.check(.eof)) break;
            continue;
        };
        try items.append(self.alloc, item);
        if (!self.match(.comma)) break;
        try commas.append(self.alloc, self.prevToken());
    }

    return .{ .items = try items.toOwnedSlice(self.alloc), .commas = try commas.toOwnedSlice(self.alloc) };
}

/// bracket key with open-bound slices like `[..]`, `[start..end]`
fn parseBracketKey(self: *Parser) anyerror!*CstNode {
    if (self.peek().type == .dotdot) {
        const dot1_tok = self.advance();
        var dots = try std.ArrayList(Token).initCapacity(self.alloc, 2);
        errdefer dots.deinit(self.alloc);
        try dots.append(self.alloc, dot1_tok);
        var dropped = try std.ArrayList(*CstNode).initCapacity(self.alloc, 2);
        errdefer dropped.deinit(self.alloc);
        return self.parseSliceRest(null, &dots, null, &dropped);
    }

    const first = try self.parseStoppingAtDotDot(0);

    if (self.match(.dotdot)) {
        var dots = try std.ArrayList(Token).initCapacity(self.alloc, 2);
        errdefer dots.deinit(self.alloc);
        try dots.append(self.alloc, self.prevToken());
        var dropped = try std.ArrayList(*CstNode).initCapacity(self.alloc, 2);
        errdefer dropped.deinit(self.alloc);
        return self.parseSliceRest(first, &dots, null, &dropped);
    }
    return first;
}

/// rest of slice after `..`; recurses like before, extra middles drop
fn parseSliceRest(
    self: *Parser,
    start: ?*CstNode,
    dots: *std.ArrayList(Token),
    seen_step: ?*CstNode,
    dropped: *std.ArrayList(*CstNode),
) anyerror!*CstNode {
    const span_start = if (start) |s| s.span else dots.items[0].span();
    if (self.check(.rbracket)) {
        return self.allocCst(
            Span.merge(span_start, self.peek().span()),
            .{ .slice = .{
                .lbracket_tok = null,
                .start = start,
                .dots = try dots.toOwnedSlice(self.alloc),
                .mid = seen_step,
                .end = null,
                .rbracket_tok = null,
                .dropped = try dropped.toOwnedSlice(self.alloc),
            } },
        );
    }

    const mid = try self.parseStoppingAtDotDot(BP.range);

    if (self.match(.dotdot)) {
        try dots.append(self.alloc, self.prevToken());
        if (seen_step) |s| try dropped.append(self.alloc, s);
        return self.parseSliceRest(start, dots, mid, dropped);
    }
    return self.allocCst(
        Span.merge(span_start, mid.span),
        .{ .slice = .{
            .lbracket_tok = null,
            .start = start,
            .dots = try dots.toOwnedSlice(self.alloc),
            .mid = seen_step,
            .end = mid,
            .rbracket_tok = null,
            .dropped = try dropped.toOwnedSlice(self.alloc),
        } },
    );
}

/// 32 tokens covers ~15 simple args
const max_generic_lookahead_tokens = 32;

/// hugging `<` with `< ident (, ident)* >(` after it
/// , lookahead only, consumes nothing
fn isGenericCallAhead(self: *Parser) bool {
    if (self.peek().type != .lt) return false;
    var i: usize = 1;
    var budget: usize = max_generic_lookahead_tokens;

    while (budget > 0) {
        budget -= 1;
        // `peekAt` clamps to eof past end, falls into `else`
        switch (self.peekAt(i).type) {
            .ident => i += 1,
            .comma => i += 1,
            .gt => {
                const lp_tok = self.peekAt(i + 1);
                return lp_tok.type == .lparen and !lp_tok.space_before;
            },
            else => return false,
        }
    }
    return false;
}

/// type args apply to paths: bare `f` or dotted `o.f`
fn isPathReceiver(node: *const CstNode) bool {
    return switch (node.kind) {
        .ident => true,
        .field => |f| isPathReceiver(f.object),
        .paren => |p| if (p.expr) |e| isPathReceiver(e) else false,
        else => false,
    };
}

const TypeParamList = struct { tps: []Token, commas: []Token, gt_tok: Token };

fn parseTypeParamList(self: *Parser) !TypeParamList {
    var tps = try std.ArrayList(Token).initCapacity(self.alloc, 2);
    errdefer tps.deinit(self.alloc);
    var commas = try std.ArrayList(Token).initCapacity(self.alloc, 2);
    errdefer commas.deinit(self.alloc);
    while (!self.check(.gt)) {
        const tp = try self.expectIdent();
        try tps.append(self.alloc, tp);
        if (!self.match(.comma)) break;
        try commas.append(self.alloc, self.prevToken());
    }
    const gt_tok = try self.expect(.gt);
    return .{ .tps = try tps.toOwnedSlice(self.alloc), .commas = try commas.toOwnedSlice(self.alloc), .gt_tok = gt_tok };
}

// peek without consuming
pub fn check(self: *Parser, kind: TokenType) bool {
    return self.peek().type == kind;
}

pub fn match(self: *Parser, kind: TokenType) bool {
    if (!self.check(kind)) return false;
    self.pos += 1;
    return true;
}

/// consume token or error: expected kind
pub fn expect(self: *Parser, kind: TokenType) error{UnexpectedToken}!Token {
    const token = self.peek();
    if (token.type != kind) return error.UnexpectedToken;
    self.pos += 1;
    return token;
}

/// consume binding ident; `type` and `import` usable as names
/// , keywords rejected otherwise
fn expectIdent(self: *Parser) error{ExpectedIdentifier}!Token {
    const token = self.peek();
    switch (token.type) {
        .ident, .kw_type, .kw_import => {},
        else => return error.ExpectedIdentifier,
    }
    self.pos += 1;
    return token;
}

/// consume member name after `.`; ident or keyword
fn expectName(self: *Parser) error{ExpectedIdentifier}!Token {
    const token = self.peek();
    if (token.type != .ident and !token.type.isKeyword())
        return error.ExpectedIdentifier;
    self.pos += 1;
    return token;
}

/// plain string for import/test names; no interpolation
/// , also returns consumed tokens so cst retains delimiters
fn expectStringLiteral(self: *Parser) error{UnexpectedToken}!cst.StringLit {
    const t = self.peek();
    if (t.type == .string) {
        _ = self.advance();
        const toks = self.alloc.dupe(Token, &.{t}) catch return error.UnexpectedToken;
        return .{ .text = t.text, .span = t.span(), .toks = toks };
    }
    if (t.type == .string_start or t.type == .ml_string_start) {
        const is_ml = t.type == .ml_string_start;
        const start_span = t.span();
        _ = self.advance();
        var toks = std.ArrayList(Token).initCapacity(self.alloc, 4) catch return error.UnexpectedToken;
        errdefer toks.deinit(self.alloc);
        toks.append(self.alloc, t) catch return error.UnexpectedToken;
        var buf = std.ArrayList(u8).initCapacity(self.alloc, 32) catch return error.UnexpectedToken;
        defer buf.deinit(self.alloc);
        var end_span = start_span;
        while (true) {
            const cur = self.peek();
            if (cur.type == .string_part or cur.type == .ml_string_part) {
                buf.appendSlice(self.alloc, cur.text) catch return error.UnexpectedToken;
                end_span = cur.span();
                toks.append(self.alloc, cur) catch return error.UnexpectedToken;
                _ = self.advance();
                continue;
            }
            if (cur.type == .interp_open) return error.UnexpectedToken; // no interp in paths
            if ((is_ml and cur.type == .ml_string_end) or (!is_ml and cur.type == .string_end)) {
                end_span = cur.span();
                toks.append(self.alloc, cur) catch return error.UnexpectedToken;
                _ = self.advance();
                break;
            }
            if (cur.type == .eof or cur.type == .invalid) return error.UnexpectedToken;
            return error.UnexpectedToken;
        }
        const raw = buf.toOwnedSlice(self.alloc) catch return error.UnexpectedToken;
        const span = Span.merge(start_span, end_span);
        const owned_toks = toks.toOwnedSlice(self.alloc) catch return error.UnexpectedToken;
        if (is_ml) {
            defer self.alloc.free(raw);
            const text = Lexer.dedentMultiline(self.alloc, raw) catch return error.UnexpectedToken;
            return .{ .text = text, .span = span, .toks = owned_toks };
        }
        return .{ .text = raw, .span = span, .toks = owned_toks };
    }
    return error.UnexpectedToken;
}

/// consume and return current token
pub fn advance(self: *Parser) Token {
    const token = self.peek();
    self.pos += 1;
    return token;
}

/// current token; pulls when lazy, never mutates `pos`
pub fn peek(self: *Parser) Token {
    return self.tokenAt(self.pos);
}

/// token at offset; pulls when lazy
pub fn peekAt(self: *Parser, offset: usize) Token {
    return self.tokenAt(self.pos + offset);
}

pub fn prevToken(self: *Parser) Token {
    if (self.pos == 0) return self.tokenAt(0);
    return self.tokenAt(self.pos - 1);
}

/// peek ident text match
fn checkIdentText(self: *Parser, text: []const u8) bool {
    const token = self.peek();
    return token.type == .ident and std.mem.eql(u8, token.text, text);
}

fn isStatementBoundary(self: *Parser, left: *const CstNode) bool {
    if (self.forcesStatementBoundary(left, self.peek().type)) return true;
    if (!expr_start_tokens.get(self.peek().type)) return false;
    return !self.canContinueExpression(left);
}

fn forcesStatementBoundary(self: *Parser, left: *const CstNode, next: TokenType) bool {
    // labeled `do /l ... end` ends a stmt like the old `labeled_block`
    if (left.kind == .do_block and left.kind.do_block.label_tok != null) {
        return expr_start_tokens.get(next);
    }
    return switch (cstEffectiveKind(left)) {
        .number => next == .lparen and !self.tokenAdjacent(left.span.end),
        .decl => expr_start_tokens.get(next),
        .assign, .compound, .fn_method, .return_expr, .break_expr, .continue_expr => expr_start_tokens.get(next),
        .call, .generic_call, .method_call, .bare_call => call_stmt_boundary_tokens.get(next),
        else => false,
    };
}

fn canContinueExpression(self: *Parser, left: *const CstNode) bool {
    const t = self.peek().type;
    // any atom continues: `:foo(` and bare `:foo` alike
    if (t == .dot or t == .lbracket or t == .assign or t == .dotdot or t == .pipe_forward or t == .atom) return true;
    if (compound_assign_table.get(t) != null) return true;
    if (logical_binding_table.get(t) != null) return true;
    if (infix_binding_table.get(t) != null) return true;
    if (t == .lparen and !self.peek().space_before) return true;
    if (self.allow_bare_calls and cstExprAllowsBareCall(left)) return bare_call_arg_start_tokens.get(t);
    return false;
}

/// parens are transparent for grammar decisions, like the old ast view
fn cstEffectiveKind(node: *const CstNode) CstKind {
    var cur = node;
    while (true) {
        switch (cur.kind) {
            .paren => |p| if (p.expr) |e| {
                cur = e;
            } else return cur.kind,
            else => return cur.kind,
        }
    }
}

/// true when expr allows bare call after it. policy A: only a plain
/// path/function value; call results and nested bare calls are errors.
fn cstExprAllowsBareCall(node: *const CstNode) bool {
    return switch (cstEffectiveKind(node)) {
        .ident, .field, .fn_def => true,
        else => false,
    };
}

fn allocCst(self: *Parser, span: Span, kind: CstKind) anyerror!*CstNode {
    return cst.allocNode(self.alloc, span, kind);
}

const InfixBindingTable = std.EnumArray(TokenType, ?BindingPower);
const infix_binding_table: InfixBindingTable = blk: {
    var table = InfixBindingTable.initFill(null);
    table.set(.eq, .{ .left = 30, .right = 31, .op = .eq });
    table.set(.neq, .{ .left = 30, .right = 31, .op = .neq });
    table.set(.lt, .{ .left = 30, .right = 31, .op = .lt });
    table.set(.gt, .{ .left = 30, .right = 31, .op = .gt });
    table.set(.lte, .{ .left = 30, .right = 31, .op = .lte });
    table.set(.gte, .{ .left = 30, .right = 31, .op = .gte });
    table.set(.plus, .{ .left = 40, .right = 41, .op = .add });
    // right-assoc like lua
    table.set(.concat, .{ .left = 41, .right = 40, .op = .concat });
    table.set(.minus, .{ .left = 40, .right = 41, .op = .sub });
    table.set(.star, .{ .left = 50, .right = 51, .op = .mul });
    table.set(.slash, .{ .left = 50, .right = 51, .op = .div });
    table.set(.floor_div, .{ .left = 50, .right = 51, .op = .int_div });
    table.set(.percent, .{ .left = 50, .right = 51, .op = .mod });
    // exponent right-assoc, tighter than unary minus
    table.set(.caret, .{ .left = 62, .right = 61, .op = .pow });
    // bitwise; shifts tightest, then band, bxor, bor
    table.set(.kw_shl, .{ .left = 48, .right = 49, .op = .shl });
    table.set(.kw_shr, .{ .left = 48, .right = 49, .op = .shr });
    table.set(.kw_band, .{ .left = 44, .right = 45, .op = .band });
    table.set(.kw_bxor, .{ .left = 43, .right = 44, .op = .bxor });
    table.set(.kw_bor, .{ .left = 42, .right = 43, .op = .bor });
    break :blk table;
};

/// `"...#{...}..."` raw parts; lowering folds plain strings and `fmt`
fn parseInterpolatedString(self: *Parser, start_tok: Token, is_multiline: bool) anyerror!*CstNode {
    var parts = try std.ArrayList(cst.CstInterpPart).initCapacity(self.alloc, 4);
    errdefer parts.deinit(self.alloc);

    const end_kind: TokenType = if (is_multiline) .ml_string_end else .string_end;

    var end_tok: ?Token = null;
    while (true) {
        const t = self.peek();
        if (t.type == .string_part or t.type == .ml_string_part) {
            const lit = self.advance();
            try parts.append(self.alloc, .{ .literal = lit });
            continue;
        }
        if (t.type == .interp_open) {
            const open_tok = self.advance();
            // empty `#{}` has no value, so error and skip it
            if (self.check(.interp_close)) {
                _ = self.advance();
                try self.recordError(.UnexpectedToken, "empty string interpolation", start_tok.span());
                continue;
            }
            const value = try self.parseExpression(0);
            var mode: cst.InterpolationMode = .plain;
            var mode_tok: ?Token = null;
            // trailing `:v`/`:?`/`:p` picks render mode
            if (self.check(.atom)) {
                const mt = self.peek();
                if (cst.interpolationModeSuffix(mt.text)) |found| {
                    mode_tok = self.advance();
                    mode = found;
                }
            }
            const close = try self.expect(.interp_close);
            try parts.append(self.alloc, .{ .interp = .{
                .open_tok = open_tok,
                .value = value,
                .mode = mode,
                .mode_tok = mode_tok,
                .close_tok = close,
            } });
            continue;
        }
        if (t.type == end_kind) {
            end_tok = self.advance();
            break;
        }
        if (t.type == .invalid or t.type == .eof) {
            // unterminated; lex error already recorded, drop the fragment
            if (t.type == .invalid) _ = self.advance();
            break;
        }
        return error.UnexpectedToken;
    }

    const end_span = if (end_tok) |e| e.span() else if (parts.items.len > 0) switch (parts.items[parts.items.len - 1]) {
        .literal => |tok| tok.span(),
        .interp => |in| in.close_tok.span(),
    } else start_tok.span();
    const span = Span.merge(start_tok.span(), end_span);
    return self.allocCst(span, .{ .interpolated = .{
        .start_tok = start_tok,
        .parts = try parts.toOwnedSlice(self.alloc),
        .end_tok = end_tok,
        .multiline = is_multiline,
    } });
}

const LogicalBindingTable = std.EnumArray(TokenType, ?LogicalBinding);
const logical_binding_table: LogicalBindingTable = blk: {
    var table = LogicalBindingTable.initFill(null);
    table.set(.kw_or, .{ .left = 10, .right = 11 });
    table.set(.kw_and, .{ .left = 20, .right = 21 });
    table.set(.kw_orelse, .{ .left = 12, .right = 13 }); // lower than `or`
    break :blk table;
};

const CompoundAssignTable = std.EnumArray(TokenType, ?cst.BinOp);
const compound_assign_table: CompoundAssignTable = blk: {
    var table = CompoundAssignTable.initFill(null);
    table.set(.plus_assign, .add);
    table.set(.minus_assign, .sub);
    table.set(.star_assign, .mul);
    table.set(.slash_assign, .div);
    table.set(.percent_assign, .mod);
    table.set(.caret_assign, .pow);
    table.set(.concat_assign, .concat);
    break :blk table;
};

const TokenSet = std.EnumArray(TokenType, bool);

fn makeTokenSet(comptime tokens: []const TokenType) TokenSet {
    var table = TokenSet.initFill(false);
    inline for (tokens) |token| table.set(token, true);
    return table;
}

const bare_call_arg_start_tokens = makeTokenSet(&.{
    .string,
    .string_start,
    .ml_string_start,
    .lsquiggly,
});

const call_stmt_boundary_tokens = makeTokenSet(&.{
    .string,
    .string_start,
    .ml_string_start,
    .lsquiggly,
});

const expr_start_tokens = makeTokenSet(&.{
    .number,    .string,    .string_start, .ml_string_start,
    .atom,      .ident,     .kw_const,     .kw_let,
    .minus,     .kw_not,    .pipe_forward, .lparen,
    .kw_fn,     .kw_if,     .kw_unless,    .kw_match,
    .kw_do,     .kw_loop,   .kw_break,     .kw_continue,
    .kw_return, .kw_import, .kw_spawn,     .kw_yield,
    .lsquiggly, .kw_type,   .kw_pub,       .eof,
});

// test smokezone

pub const testing = struct {
    pub fn parseOne(alloc: std.mem.Allocator, source: []const u8) !*Node {
        const tokens = try Lexer.lexAt(alloc, source);
        const root = try parseTokens(alloc, tokens, .{});
        // mirror the old single-statement unwrap so shape tests read cleanly
        if (root.kind == .root and root.kind.root.stmts.len == 1) return root.kind.root.stmts[0];
        return root;
    }
};

test "parses string interpolation as sugar nodes" {
    // sugar round-trips
    const cases = [_][]const u8{
        "\"hello #{name}\"",
        "\"#{value:?} #{value:p}\"",
        "\"literal {{brace}}\"",
    };
    for (cases) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const root = try testing.parseOne(arena.allocator(), src);
        try std.testing.expect(root.kind == .interpolated);
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const root = try testing.parseOne(arena.allocator(), "\"#{value:?} #{value:p}\"");
        const parts = root.kind.interpolated.parts;
        try std.testing.expectEqual(@as(usize, 3), parts.len);
        try std.testing.expect(parts[0] == .interp and parts[0].interp.mode == .debug);
        try std.testing.expect(parts[1] == .literal);
        try std.testing.expect(parts[2] == .interp and parts[2].interp.mode == .pretty);
    }
}

test "lowering turns sugar into the fmt call shape" {
    const cases = [_]struct { src: []const u8, format: []const u8, nargs: usize }{
        .{ .src = "\"hello #{name}\"", .format = "hello %v", .nargs = 2 },
        .{ .src = "\"#{value:?} #{value:p}\"", .format = "%? %p", .nargs = 3 },
        .{ .src = "\"100% #{x}\"", .format = "100%% %v", .nargs = 2 },
        .{ .src = "\"\"\"\n  hello #{name}\n  \"\"\"", .format = "hello %v", .nargs = 2 },
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const root = try testing.parseOne(alloc, c.src);

        const lowered = try @import("pipeline/interpolation.zig").lowerRoot(alloc, root);
        try std.testing.expect(lowered.kind == .call);
        try std.testing.expectEqualStrings("fmt", lowered.kind.call.callee.kind.ident.tok.text);
        try std.testing.expectEqual(c.nargs, lowered.kind.call.args.len);
        try std.testing.expectEqualStrings(c.format, lowered.kind.call.args[0].kind.string.tok.text);
    }
    // no-interp strings fold to plain strings
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const root = try testing.parseOne(alloc, "\"literal {{brace}}\"");
        const lowered = try @import("pipeline/interpolation.zig").lowerRoot(alloc, root);
        try std.testing.expect(lowered.kind == .string);
        try std.testing.expectEqualStrings("literal {brace}", lowered.kind.string.tok.text);
    }
}

test "unknown interpolation mode is an error" {
    // lone atom interpolation still lowers like before (value `:d`, plain)
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const root = try testing.parseOne(alloc, "\"#{:d}\"");
        const lowered = try @import("pipeline/interpolation.zig").lowerRoot(alloc, root);
        try std.testing.expect(lowered.kind == .call);
        try std.testing.expectEqualStrings("fmt", lowered.kind.call.callee.kind.ident.tok.text);
        try std.testing.expectEqual(@as(usize, 2), lowered.kind.call.args.len);
        try std.testing.expectEqualStrings("%v", lowered.kind.call.args[0].kind.string.tok.text);
    }

    // ... but a mode suffix after a value must be a known one
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const tokens = try Lexer.lexAt(alloc, "print \"#{t:d}\"");
        const result = try parseTokensReport(alloc, tokens, .{});
        switch (result) {
            .ok => return error.ExpectedParseFailure,
            .err => |failure| {
                try std.testing.expect(diagnostic.firstError(failure.report) != null);
            },
        }
    }
}

test "interpolation value nodes carry real source spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(alloc, "print \"hi #{name}\"");
    const tmpl = root.kind.bare_call.arg.kind.interpolated;
    try std.testing.expectEqual(@as(usize, 2), tmpl.parts.len);
    try std.testing.expectEqualStrings("hi ", tmpl.parts[0].literal.text);
    const value = tmpl.parts[1].interp.value;
    try std.testing.expectEqual(@as(u32, 1), value.span.line);
    try std.testing.expectEqual(@as(u32, 13), value.span.column);
    try std.testing.expectEqual(@as(usize, 12), value.span.start);
    try std.testing.expectEqual(@as(usize, 16), value.span.end);
}

test "interpolation spans survive multiline dedent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\print """
        \\  #{a}
        \\  #{b}"""
    ;

    const root = try testing.parseOne(alloc, src);
    // sugar keeps raw lits; dedent is at lowering
    const tmpl = root.kind.bare_call.arg.kind.interpolated;

    try std.testing.expect(tmpl.multiline);
    try std.testing.expectEqual(@as(usize, 4), tmpl.parts.len);
    try std.testing.expectEqualStrings("\n  ", tmpl.parts[0].literal.text);
    try std.testing.expectEqualStrings("\n  ", tmpl.parts[2].literal.text);

    const a = tmpl.parts[1].interp.value;
    const b = tmpl.parts[3].interp.value;

    try std.testing.expectEqual(@as(u32, 2), a.span.line);
    try std.testing.expectEqual(@as(u32, 5), a.span.column);
    try std.testing.expectEqual(@as(usize, 14), a.span.start);
    try std.testing.expectEqual(@as(usize, 15), a.span.end);
    try std.testing.expectEqual(@as(u32, 3), b.span.line);
    try std.testing.expectEqual(@as(u32, 5), b.span.column);
    try std.testing.expectEqual(@as(usize, 21), b.span.start);
    try std.testing.expectEqual(@as(usize, 22), b.span.end);
}

test "interpolation spans survive nested strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // nested strings need no escapes
    const root = try testing.parseOne(alloc, "print \"a #{ \"b #{c}\" } d\"");
    const outer = root.kind.bare_call.arg.kind.interpolated;
    try std.testing.expectEqual(@as(usize, 3), outer.parts.len);
    const inner = outer.parts[1].interp.value.kind.interpolated;
    // trailing lit empty, so no third part
    try std.testing.expectEqual(@as(usize, 2), inner.parts.len);
    const c = inner.parts[1].interp.value;
    try std.testing.expectEqual(@as(u32, 1), c.span.line);
    try std.testing.expectEqual(@as(u32, 18), c.span.column);
    try std.testing.expectEqual(@as(usize, 17), c.span.start);
    try std.testing.expectEqual(@as(usize, 18), c.span.end);
}
test "parses doc comment on function declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ #* adds *#
        \\ fn add(a, b) a + b
    ;
    const root = try testing.parseOne(alloc, src);
    try std.testing.expect(root.kind == .decl);
    try std.testing.expect(root.kind.decl.inner.kind == .binding);
    const b = root.kind.decl.inner.kind.binding;
    try std.testing.expect(b.value.kind == .fn_def);
    try std.testing.expectEqualStrings(" adds ", root.doc_tok.?.text);
}

test "doc comment attaches to non-fn const binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ #* a plain value *#
        \\ const a = 5
    ;
    const root = try testing.parseOne(alloc, src);
    try std.testing.expect(root.kind == .decl);
    const b = root.kind.decl.inner.kind.binding;
    try std.testing.expect(b.value.kind == .number);
    try std.testing.expectEqualStrings(" a plain value ", root.doc_tok.?.text);
}

test "parses @native annotation on function declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ @native
        \\ fn add(a, b) a + b
    ;
    const root = try testing.parseOne(alloc, src);
    const value = root.kind.decl.inner.kind.binding.value;
    try std.testing.expect(value.kind == .fn_def);
    try std.testing.expect(root.attrs.len == 1);
    try std.testing.expect(root.doc_tok == null);
}

test "parses @native with a doc comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ #* adds two numbers *#
        \\ @native fn add(a, b) a + b
    ;
    const root = try testing.parseOne(alloc, src);
    const b = root.kind.decl.inner.kind.binding;
    try std.testing.expect(b.value.kind == .fn_def);
    try std.testing.expect(root.attrs.len == 1);
    try std.testing.expectEqualStrings(" adds two numbers ", root.doc_tok.?.text);
}

test "unknown attribute is a parse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.lexAt(alloc, "@bar fn foo() 1");
    try std.testing.expectError(error.UnknownAttribute, parseTokens(alloc, tokens, .{}));
}
test "parses import statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(alloc, "import \"json\"");
    try std.testing.expect(root.kind == .import);
    const im = root.kind.import;
    try std.testing.expectEqual(@as(usize, 1), im.items.len);
    try std.testing.expectEqualStrings("json", im.items[0].path.text);
    try std.testing.expect(im.items[0].name_tok == null);
    try std.testing.expect(!im.pub_);
}

test "parses multi-import table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const root = try testing.parseOne(alloc, "import {\"a\", \"b\"}");
        try std.testing.expect(root.kind == .import);
        const items = root.kind.import.items;
        try std.testing.expectEqual(@as(usize, 2), items.len);
        try std.testing.expectEqualStrings("a", items[0].path.text);
        try std.testing.expectEqualStrings("b", items[1].path.text);
    }
    {
        const root = try testing.parseOne(alloc, "import {x = \"a\"}");
        try std.testing.expect(root.kind == .import);
        const items = root.kind.import.items;
        try std.testing.expectEqual(@as(usize, 1), items.len);
        try std.testing.expectEqualStrings("x", items[0].name_tok.?.text);
        try std.testing.expectEqualStrings("a", items[0].path.text);
    }
    {
        const root = try testing.parseOne(alloc, "import {x = \"a\", \"b\"}");
        try std.testing.expect(root.kind == .import);
        const items = root.kind.import.items;
        try std.testing.expectEqual(@as(usize, 2), items.len);
        try std.testing.expectEqualStrings("x", items[0].name_tok.?.text);
        try std.testing.expectEqualStrings("b", items[1].path.text);
    }
}

test "parses pub const with pub_ flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(alloc, "pub const x = 1");
    try std.testing.expect(root.kind == .decl);
    try std.testing.expect(root.kind.decl.pub_);
    try std.testing.expect(root.kind.decl.kind == .@"const");
}

test "parses pub import statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(alloc, "pub import \"json\"");
    try std.testing.expect(root.kind == .import);
    try std.testing.expect(root.kind.import.pub_);
    try std.testing.expectEqualStrings("json", root.kind.import.items[0].path.text);
}

test "parses pub fn with pub_ flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(alloc, "pub fn f() 42");
    try std.testing.expect(root.kind == .decl);
    try std.testing.expect(root.kind.decl.pub_);
}
test "parses pub type with pub_ flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(alloc, "pub type MyInt = number");
    try std.testing.expect(root.kind == .decl);
    try std.testing.expect(root.kind.decl.pub_);
    try std.testing.expect(root.kind.decl.kind == .type_alias_decl);
}

test "parses declare as an ambient decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(alloc, "pub declare ring = fn(volume: number, label: string) -> bool");
    try std.testing.expect(root.kind == .decl);
    try std.testing.expect(root.kind.decl.pub_);
    try std.testing.expect(root.kind.decl.kind == .declare_decl);
    const alias = root.kind.decl.inner.kind.type_alias;
    try std.testing.expectEqualStrings("ring", alias.segs[0].text);
    try std.testing.expect(alias.type.kind == .function);
}

test "declare fn doc comment attaches to the decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(
        alloc,
        "#* lights the lamp loudness *# declare lamp = fn(volume: number) -> bool",
    );
    try std.testing.expect(root.kind == .decl);
    try std.testing.expectEqualStrings(
        " lights the lamp loudness ",
        root.doc_tok.?.text,
    );
}

test "doc comment attaches to any decl, docs land on the declared thing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(alloc, "#* a doc *# const x = 42");
    try std.testing.expectEqualStrings(" a doc ", root.doc_tok.?.text);
}

test "declare defaults to pub" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try testing.parseOne(alloc, "declare ring = fn() -> number");
    try std.testing.expect(root.kind.decl.pub_);
}

fn parseKind(alloc: std.mem.Allocator, src: []const u8) !cst.CstKind {
    const root = try testing.parseOne(alloc, src);
    return root.kind;
}

test "parses repeated paren calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // `f()()` nests calls; each level is a hug call
    var n = try testing.parseOne(alloc, "f()()()()");
    var depth: usize = 0;
    while (n.kind == .call) : (depth += 1) {
        n = n.kind.call.callee;
    }
    try std.testing.expect(n.kind == .ident);
    try std.testing.expectEqual(@as(usize, 4), depth);
}

test "paren calls require a hug" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // hugging call
    try std.testing.expect((try parseKind(alloc, "print(\"hi\")")) == .call);
    // newline/space breaks the hug: two statements in a root
    {
        const root = try testing.parseOne(alloc, "print\n(\"hi\")");
        try std.testing.expect(root.kind == .root);
        try std.testing.expectEqual(@as(usize, 2), root.kind.root.stmts.len);
    }
    {
        const root = try testing.parseOne(alloc, "print (\"hi\")");
        try std.testing.expect(root.kind == .root);
        try std.testing.expectEqual(@as(usize, 2), root.kind.root.stmts.len);
    }
    // parenthesized callee still calls when hugging
    try std.testing.expect((try parseKind(alloc, "(f)(1)")) == .call);
    {
        const root = try testing.parseOne(alloc, "(f) (1)");
        try std.testing.expect(root.kind == .root);
        try std.testing.expectEqual(@as(usize, 2), root.kind.root.stmts.len);
    }
    // colon calls are method calls, raw until lowering
    {
        const k = try parseKind(alloc, "t:foo(1)");
        try std.testing.expect(k == .method_call);
        try std.testing.expectEqualStrings(":foo", k.method_call.atom_tok.text);
    }
    {
        const root = try testing.parseOne(alloc, "t:foo (1)");
        try std.testing.expect(root.kind == .root);
        // `t`, `:foo`, `(1)` stay three separate statements without a hug
        try std.testing.expectEqual(@as(usize, 3), root.kind.root.stmts.len);
    }
}

test "dotted heads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const typed = try testing.parseOne(alloc, "pub type uri.Hi<T> = {n: T}");
    try std.testing.expect(typed.kind.decl.kind == .type_alias_decl);
    const alias = typed.kind.decl.inner.kind.type_alias;
    try std.testing.expectEqual(@as(usize, 2), alias.segs.len);
    try std.testing.expectEqualStrings("uri", alias.segs[0].text);
    try std.testing.expectEqualStrings("Hi", alias.segs[1].text);
    try std.testing.expectEqual(@as(usize, 1), alias.tps.len);
    try std.testing.expectEqualStrings("T", alias.tps[0].text);

    // reject core slots and deep paths
    for ([_][]const u8{
        "pub type string:foo = number",
    }) |source| {
        try std.testing.expectError(error.UnexpectedToken, testing.parseOne(alloc, source));
    }
}

test "generic call angle brackets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try testing.parseOne(alloc, "id<number>(42)");
    const call = node.kind.generic_call;
    try std.testing.expectEqualStrings("id", call.receiver.kind.ident.tok.text);
    try std.testing.expectEqual(@as(usize, 1), call.type_args.len);
    try std.testing.expectEqualStrings("number", call.type_args[0].text);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);

    const dotted = try testing.parseOne(alloc, "m.id<T, U>(a, b)");
    const dcall = dotted.kind.generic_call;
    try std.testing.expectEqual(@as(usize, 2), dcall.type_args.len);
    try std.testing.expectEqualStrings("T", dcall.type_args[0].text);
    try std.testing.expectEqualStrings("U", dcall.type_args[1].text);
    try std.testing.expectEqual(@as(usize, 2), dcall.args.len);

    // spaced `<` is comparison; only hugging `f<T>(x)` applies type args
    {
        const k = try parseKind(alloc, "f <T>(x)");
        try std.testing.expect(k == .binary);
    }
    {
        const k = try parseKind(alloc, "f<1>(x)");
        try std.testing.expect(k == .binary);
    }
}

test "cst keeps call delimiters; lowering matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.lexAt(alloc, "f(1, 2)");
    defer alloc.free(tokens);
    const root = try parseTokens(alloc, tokens, .{});
    try std.testing.expect(root.kind == .root);
    try std.testing.expectEqual(@as(usize, 1), root.kind.root.stmts.len);
    const call = root.kind.root.stmts[0];
    try std.testing.expect(call.kind == .call);
    try std.testing.expectEqual(TokenType.lparen, call.kind.call.lparen_tok.type);
    try std.testing.expectEqual(TokenType.rparen, call.kind.call.rparen_tok.type);
    try std.testing.expectEqual(@as(usize, 1), call.kind.call.commas.len);
    try std.testing.expectEqual(@as(usize, 2), call.kind.call.args.len);

    // desugared shape matches: plain call with two args
    try std.testing.expect(call.kind.call.args.len == 2);
}

test "cst pipe stays raw until lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.lexAt(alloc, "x |> f");
    defer alloc.free(tokens);
    const root = try parseTokens(alloc, tokens, .{});
    const pipe = root.kind.root.stmts[0];
    try std.testing.expect(pipe.kind == .pipe);
    try std.testing.expectEqual(TokenType.pipe_forward, pipe.kind.pipe.pipe_tok.type);

    // shared desugar turns it into a call
    const desugared = try cst.desugarPipe(alloc, pipe.kind.pipe.left, pipe.kind.pipe.right, pipe.span);
    try std.testing.expect(desugared.kind == .call);
    try std.testing.expectEqualStrings("f", desugared.kind.call.callee.kind.ident.tok.text);
}

test "cst method def keeps head tokens; lowering assigns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.lexAt(alloc, "fn t:inc(x) x");
    defer alloc.free(tokens);
    const root = try parseTokens(alloc, tokens, .{});
    const m = root.kind.root.stmts[0];
    try std.testing.expect(m.kind == .fn_method);
    try std.testing.expectEqualStrings("t", m.kind.fn_method.head.method_colon.obj_tok.text);

    // single explicit param; the compiler prepends `self` for colon methods
    try std.testing.expectEqual(@as(usize, 1), m.kind.fn_method.params.len);
}

test "retained tokens exactly cover lexed tokens" {
    const sources = [_][]const u8{
        "let x = 1 # hi\nlet y = 2",
        "f(1, 2)",
        "x |> f |> g",
        "fn add(a, b) a + b",
        "fn t:inc(x) x",
        "fn o.f(x) x",
        "if a b else c",
        "match x | 1 => a | _ => b",
        "for i in 0..10 do i end",
        "t = { a = 1, [k] = 2, 3 }",
        "import {x = \"a\", \"b\"}",
        "test/skip \"t\" do 1 end",
        "type T = number | string",
        "declare f = fn(a: number) -> bool",
        // gone for now but still wanna have it here to make sure it's lossless
        "proc inc!(n) n + 1",
        "\"hi #{name:?} done\"",
        "`a %x c`",
        "a..b",
        "t[1..]",
        "(1)",
        "@native fn f() 1",
        "#* doc *# const x = 1",
    };
    for (sources) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const out = try Lexer.lexAll(alloc, src);
        defer Lexer.freeLexOutput(alloc, out);
        const root = parseTokens(alloc, out.tokens, .{}) catch |err| {
            std.debug.print("cst cover failed on: {s}\n", .{src});
            return err;
        };
        const kept = try cst.retainedTokens(alloc, root);
        defer alloc.free(kept);
        try std.testing.expectEqual(out.tokens.len, kept.len);
        for (out.tokens, kept) |want, got| {
            try std.testing.expectEqual(want.type, got.type);
            try std.testing.expectEqual(want.start, got.start);
            try std.testing.expectEqual(want.end, got.end);
        }
    }
}

test "parse retains trivia on the root for fmt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "let x = 1 # hi\n\n# bye\nlet y = 2 # tail";
    const root = try parseSource(alloc, src, .{});
    try std.testing.expect(root.kind == .root);
    const trivia = root.kind.root.trivia;
    // `# hi`, `# bye`, `# tail`
    try std.testing.expectEqual(@as(usize, 3), trivia.len);

    // every comment resolves through some token's leading range
    const kept = try cst.retainedTokens(alloc, root);
    defer alloc.free(kept);
    var seen: [3]bool = .{ false, false, false };
    for (kept) |tok| {
        for (cst.leadingTriviaFrom(trivia, tok)) |tr| {
            for (trivia, 0..) |t, i| {
                if (t.start == tr.start and t.end == tr.end) seen[i] = true;
            }
        }
    }
    for (seen) |s| try std.testing.expect(s);

    // blank line between the bindings survives as newline counts
    var second_let: ?Token = null;
    for (kept) |t| {
        if (t.type == .kw_let and t.start > 0) second_let = t;
    }
    try std.testing.expect(second_let.?.newlines_before >= 2);

    // rebuilds (expansion, lowering) preserve the store
    const rebuilt = try cst.walkCstExpr(alloc, root, TestAliasCtx, .{});
    try std.testing.expectEqual(trivia.len, rebuilt.kind.root.trivia.len);
}

const TestAliasCtx = struct {
    pub fn walk(_: @This(), allocator: std.mem.Allocator, node: *CstNode, ctx: @This()) std.mem.Allocator.Error!*CstNode {
        return cst.walkCstExpr(allocator, node, @This(), ctx);
    }
};
