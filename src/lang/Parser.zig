const std = @import("std");

const lang = @import("./root.zig");
const ast = lang.ast;
const Expr = ast.Expr;
const Node = ast.Node;
const Span = ast.Span;
const testing_helpers = @import("testing.zig");
const lexer = lang.Lexer;
const Token = lexer.Token;
const TokenType = lexer.TokenType;
const type_serde = @import("type_serde.zig");

const BP: struct {
    const i = comptime_int;
    assign: i = 5,
    compound: i = 5, // += -= *= /= %= same as assign, right-associative
    comp: i = 0,
    pipe: i = 15,
    range: i = 36, // `a < b..c` is `(a < b)..c`
    bare_call: i = 70, // `f "str"` or `f { a = 1 }`
    try_op: i = 80, // ? postfix -- `x?`, err propagation
    suffix: i = 90, // . [] () :()
} = .{};

const diagnostic = @import("./diagnostic.zig");

// left < right = left-assoc    a + b + c :== (a + b) + c
// left > right = right-assoc   a = b = c :== a = (b = c)
const BindingPower = struct {
    left: u8,
    right: u8,
    op: ast.BinOp,
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
};

pub const ParseResult = union(enum) {
    ok: *Node,
    err: ParseFailure,
};

//
// api
//

pub fn parseTokens(allocator: std.mem.Allocator, tokens: []const Token) anyerror!*Node {
    return switch (try parseTokensReport(allocator, tokens)) {
        .ok => |expr| expr,
        .err => |failure| switch (failure.kind) {
            .UnexpectedToken => error.UnexpectedToken,
            .ExpectedIdentifier => error.ExpectedIdentifier,
            .ExpectedMatchArm => error.ExpectedMatchArm,
            else => error.ParseFailed,
        },
    };
}

pub fn parseTokensReport(alloc: std.mem.Allocator, tokens: []const Token) anyerror!ParseResult {
    var parser = Parser{ .alloc = alloc, .tokens = tokens };
    try parser.initErrors();
    const expr = parser.parse() catch |err| switch (err) {
        error.UnexpectedToken => {
            const token = parser.peek();
            const parts = try alloc.alloc(diagnostic.Part, 2);
            parts[0] = diagnostic.Part{ .@"error" = try alloc.dupe(u8, "unexpected token") };
            parts[1] = .{ .span = .{ .span = token.span(), .role = .primary } };
            return .{ .err = .{
                .kind = .UnexpectedToken,
                .report = .{ .parts = parts, .message = parts[0].@"error" },
            } };
        },
        error.ExpectedIdentifier => {
            const token = parser.peek();
            const parts = try alloc.alloc(diagnostic.Part, 2);
            parts[0] = diagnostic.Part{ .@"error" = try alloc.dupe(u8, "expected identifier") };
            parts[1] = .{ .span = .{ .span = token.span(), .role = .primary } };
            return .{ .err = .{
                .kind = .ExpectedIdentifier,
                .report = .{ .parts = parts, .message = parts[0].@"error" },
            } };
        },
        error.ExpectedMatchArm => {
            const token = parser.peek();
            const parts = try alloc.alloc(diagnostic.Part, 2);
            parts[0] = diagnostic.Part{ .@"error" = try alloc.dupe(u8, "match expression requires at least one arm") };
            parts[1] = .{ .span = .{ .span = token.span(), .role = .primary } };
            return .{ .err = .{
                .kind = .ExpectedMatchArm,
                .report = .{ .parts = parts, .message = parts[0].@"error" },
            } };
        },
        else => return err,
    };
    if (parser.hasErrors()) {
        return .{ .err = try parser.finishFailure() };
    }
    return .{ .ok = expr };
}

/// recursive descent + pratt hybrid
/// parser holds state: tokens, pos, stop conditions, bare-call toggle
/// ret: block if multiple exprs, single node otherwise
const Parser = @This();
alloc: std.mem.Allocator,
tokens: []const Token,
pos: usize = 0,
stop_token: ?TokenType = null,
allow_bare_calls: bool = true, // permit `f "str"`, disabled in pattern positions
stop_on_stmt_start: bool = false, // treat statement-starting tokens as expr boundaries
errors: std.ArrayList(diagnostic.Part) = .empty,
error_depths: std.ArrayList(usize) = .empty,
errors_inited: bool = false,
first_error_kind: ?Kind = null,
first_error_message: []const u8 = "",
had_errors: bool = false,
depth: usize = 0,

fn initErrors(self: *Parser) !void {
    self.errors = try std.ArrayList(diagnostic.Part).initCapacity(self.alloc, 8);
    self.error_depths = try std.ArrayList(usize).initCapacity(self.alloc, 8);
    self.errors_inited = true;
}

fn parse(self: *Parser) anyerror!*Node {
    const exprs = try self.parseExprListUntil(.eof);
    if (!self.check(.eof)) {
        const token = self.peek();
        try self.recordError(.UnexpectedToken, "unexpected token", token.span());
        self.pos = self.tokens.len - 1;
    }
    const eof = self.peek();
    if (exprs.len == 1) return exprs[0];
    const node = try self.allocExpr(ast.spanFromNodes(exprs, eof.span()), .{ .block = exprs });
    node.synthetic_block = true;
    return node;
}

fn hasErrors(self: *Parser) bool {
    return self.had_errors;
}

fn finishFailure(self: *Parser) anyerror!ParseFailure {
    var parts = try self.errors.toOwnedSlice(self.alloc);
    const depths = try self.error_depths.toOwnedSlice(self.alloc);
    defer self.alloc.free(depths);

    if (parts.len >= 2 and depths.len > 0) {
        var max_depth: usize = 0;
        for (depths) |d| {
            if (d > max_depth) max_depth = d;
        }
        var kept = try std.ArrayList(diagnostic.Part).initCapacity(self.alloc, parts.len);
        defer kept.deinit(self.alloc);
        for (depths, 0..) |d, idx| {
            if (d == max_depth) {
                const base = idx * 2;
                if (base + 1 < parts.len) {
                    try kept.append(self.alloc, parts[base]);
                    try kept.append(self.alloc, parts[base + 1]);
                }
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

fn recordError(self: *Parser, kind: Kind, message: []const u8, span: ast.Span) !void {
    self.had_errors = true;
    const owned = try self.alloc.dupe(u8, message);
    if (self.first_error_kind == null) {
        self.first_error_kind = kind;
        self.first_error_message = message;
    }
    try self.errors.append(self.alloc, .{ .@"error" = owned });
    try self.errors.append(self.alloc, .{ .span = .{ .span = span, .role = .primary } });
    try self.error_depths.append(self.alloc, self.depth);
}

fn syncToNextStatement(self: *Parser, terminator: TokenType) void {
    if (self.check(terminator) or self.check(.eof)) return;
    self.pos = @min(self.pos + 1, self.tokens.len - 1);
    while (!self.check(terminator) and !self.check(.eof)) {
        if (expr_start_tokens.get(self.peek().type)) break;
        self.pos += 1;
    }
}

/// starts with a prefix node, then consumes infix/postfix ops while binding power allows
/// min_bp is the floor; if an operator's left power is below this, itll stop and return
fn parseExpression(self: *Parser, min_bp: u8) anyerror!*Node {
    self.depth += 1;
    defer self.depth -= 1;
    var left = try self.parsePrefix();

    while (true) {
        if (self.check(.semicolon)) break;
        if (self.stop_token) |stop| if (self.check(stop)) break;
        if (self.stop_on_stmt_start and self.isStatementBoundary(left)) break;

        // postfix `obj.field` or `obj.0` (numeric index sugar)
        if (self.match(.dot)) {
            if (self.peek().type == .number) {
                const num = self.advance();
                const key = try self.allocExpr(num.span(), .{ .number = .{ .value = std.fmt.parseFloat(f64, num.text) catch return error.InvalidNumber } });
                left = try self.allocExpr(Span.merge(left.span, num.span()), .{
                    .index = .{ .object = left, .key = key },
                });
            } else {
                const name = try self.expectIdent();
                left = try self.allocExpr(Span.merge(left.span, name.span()), .{
                    .field = .{ .object = left, .name = name.text },
                });
            }
            continue;
        }

        // postfix: method call `obj:method(args)`; sugar for `obj.field(args)` with implicit self
        if (self.peek().type == .hash and self.peekAt(1).type == .lparen) {
            const method = self.advance();
            _ = try self.expect(.lparen);
            const call_args = try self.parseDelimitedExprList(.rparen);
            const close = try self.expect(.rparen);
            const callee = try self.allocExpr(Span.merge(left.span, method.span()), .{
                .field = .{ .object = left, .name = method.text[1..] },
            });
            left = try self.allocExpr(Span.merge(left.span, close.span()), .{
                .call = .{ .callee = callee, .args = call_args, .implicit_self = true },
            });
            continue;
        }

        // postfix: generic call `f[T](args)` or index `obj[key]`
        if (self.peek().type == .lbracket) {
            if (left.expr == .ident) {
                var i: usize = 1;
                var is_type_args = false;
                while (self.pos + i < self.tokens.len) {
                    switch (self.tokens[self.pos + i].type) {
                        .ident => i += 1,
                        .comma => i += 1,
                        .rbracket => {
                            if (self.pos + i + 1 < self.tokens.len and self.tokens[self.pos + i + 1].type == .lparen)
                                is_type_args = true;
                            break;
                        },
                        else => break,
                    }
                }
                if (is_type_args) {
                    _ = try self.expect(.lbracket);
                    const type_args = try self.parseTypeParamList();
                    _ = try self.expect(.lparen);
                    const args = try self.parseDelimitedExprList(.rparen);
                    const close = try self.expect(.rparen);
                    left = try self.allocExpr(Span.merge(left.span, close.span()), .{
                        .call = .{ .callee = left, .args = args, .type_args = type_args },
                    });
                    continue;
                }
            }
            _ = try self.expect(.lbracket);
            const key = try self.parseBracketKey();
            const close = try self.expect(.rbracket);
            left = try self.allocExpr(Span.merge(left.span, close.span()), .{
                .index = .{ .object = left, .key = key },
            });
            continue;
        }

        // postfix: paren call `f(args)`; only if f allows it (ident, field, call, fn, index)
        if (self.peek().type == .lparen and (exprAllowsParenCall(left) or self.tokenAdjacent(left.span.end))) {
            _ = try self.expect(.lparen);
            const args = try self.parseDelimitedExprList(.rparen);
            const close = try self.expect(.rparen);
            left = try self.allocExpr(Span.merge(left.span, close.span()), .{
                .call = .{ .callee = left, .args = args },
            });
            continue;
        }

        // postfix: bare call `f "str"` or `f { a = 1 }`
        if (self.allow_bare_calls and self.isBareCallArgumentStart(left)) {
            const bp: u8 = BP.bare_call;
            if (bp < min_bp) break;
            const arg = try self.parseExpression(bp);
            var args = try std.ArrayList(*Node).initCapacity(self.alloc, 1);
            errdefer args.deinit(self.alloc);
            try args.append(self.alloc, arg);
            left = try self.allocExpr(Span.merge(left.span, arg.span), .{
                .call = .{ .callee = left, .args = try args.toOwnedSlice(self.alloc) },
            });
            continue;
        }

        // infix: assignment `x = y`; right-associative, converts lhs to pattern
        if (BP.assign >= min_bp and self.match(.assign)) {
            const value = try self.parseExpression(BP.assign);
            left = try self.allocExpr(Span.merge(left.span, value.span), .{
                .assign_expr = .{ .target = try self.exprToPattern(left), .value = value },
            });
            continue;
        }

        // infix: comp assign `x += y`; lowered in the compiler single-eval
        const comp_binop = compound_assign_table.get(self.peek().type);
        if (BP.compound >= min_bp and comp_binop != null) {
            const binop = comp_binop.?;
            _ = self.advance();

            const right = try self.parseExpression(BP.compound);

            left = try self.allocExpr(Span.merge(left.span, right.span), .{
                .compound_assign = .{ .target = try self.exprToPattern(left), .op = binop, .value = right },
            });
            continue;
        }

        // infix: range `start..end` or `start..step..end` the special three-part form
        // stop_token trick prevents `0..2..10` from parsing as `0..(2..10)`
        if (self.match(.dotdot)) {
            const prev_stop = self.stop_token;
            self.stop_token = .dotdot;
            const step_or_end = self.parseExpression(BP.range) catch |err| {
                self.stop_token = prev_stop;
                return err;
            };
            self.stop_token = prev_stop;

            const has_step = self.match(.dotdot);
            const end_node = if (has_step) try self.parseExpression(BP.range) else step_or_end;
            const step_node = if (has_step)
                step_or_end
            else
                try self.allocExpr(step_or_end.span, .{ .number = .{ .value = 1, .is_float = false } });
            left = try self.buildRangeExpr(left, end_node, step_node);
            continue;
        }

        // infix: logical `and` `or` `orelse`
        const op = self.peek().type;
        if (logical_binding_table.get(op)) |binding| {
            if (binding.left < min_bp) break;
            _ = self.advance();
            const right = try self.parseExpression(binding.right);
            left = try self.allocExpr(Span.merge(left.span, right.span), switch (op) {
                .kw_and => .{ .and_expr = .{ .left = left, .right = right } },
                .kw_or => .{ .or_expr = .{ .left = left, .right = right } },
                .kw_orelse => .{ .orelse_expr = .{ .left = left, .right = right } },
                else => return error.UnexpectedToken,
            });
            continue;
        }

        // infix: pipe forward `|>`
        if (op == .pipe_forward) {
            const bp: u8 = BP.pipe;
            if (bp < min_bp) break;
            _ = self.advance();

            const into_what = self.peek().type;
            switch (into_what) {
                // `x |> :method(args)` => `x:method(args)`
                // .hash => {
                //     const hash_tok = self.advance();
                //     const method_name = hash_tok.text[1..];
                //     var args: []*Node = &.{};
                //     if (self.check(.lparen)) {
                //         _ = try self.expect(.lparen);
                //         args = try self.parseDelimitedExprList(.rparen);
                //         _ = try self.expect(.rparen);
                //     }
                //     const callee = try self.allocExpr(hash_tok.span(), .{
                //         .field = .{ .object = left, .name = method_name },
                //     });
                //     left = try self.allocExpr(
                //         Span.merge(left.span, if (args.len > 0) args[args.len - 1].span else hash_tok.span()),
                //         .{ .call = .{ .callee = callee, .args = args, .implicit_self = true } },
                //     );
                //     continue;
                // },
                // `x |> match ...` -- pipe into match expression
                .kw_match => {
                    left = try self.parseMatch(self.advance(), left);
                    continue;
                },
                // `x |> fn(p) body` or `x |> f(y)`; desugar to call with x as first arg
                else => {
                    const right = if (into_what == .kw_fn)
                        try self.parseFnWithBodyMin(self.advance(), bp + 1)
                    else
                        // parse the whole rhs at "tighter than pipe" so
                        // placeholders can live inside infix chains, e.g.
                        // `x |> "aaa" ~ _:upper()`; chained pipes and
                        // or/orelse/assign still bind looser and stay outside
                        try self.parseExpression(BP.pipe + 1);
                    left = try self.desugarPipe(left, right);
                    continue;
                },
            }
        }

        // postfix: try operator `x?`
        if (op == .huh) {
            const bp: u8 = BP.try_op;
            if (bp < min_bp) break;
            _ = self.advance();
            left = try self.allocExpr(Span.merge(left.span, left.span), .{ .try_expr = left });
            continue;
        }

        // infix: math/compare ops; look up bp, consume, recurse
        const binding = infix_binding_table.get(op) orelse break;
        if (binding.left < min_bp) break;
        _ = self.advance();
        const right = try self.parseExpression(binding.right);
        left = try self.allocExpr(Span.merge(left.span, right.span), .{
            .binary = .{ .op = binding.op, .left = left, .right = right },
        });
    }

    return left;
}

/// literals, keywords, unary ops, and statement forms
fn parsePrefix(self: *Parser) anyerror!*Node {
    self.depth += 1;
    defer self.depth -= 1;
    const token = self.advance();
    return switch (token.type) {
        .number => blk: {
            const parsed = std.zig.parseNumberLiteral(token.text);
            const value: f64 = switch (parsed) {
                .int => |n| @floatFromInt(n),
                .float => std.fmt.parseFloat(f64, token.text) catch {
                    try self.recordError(.InvalidNumber, "invalid float literal", token.span());
                    break :blk self.allocExpr(token.span(), .{ .number = .{ .value = 0, .is_float = false } });
                },
                .big_int => {
                    try self.recordError(.InvalidNumber, "number literal too large", token.span());
                    break :blk self.allocExpr(token.span(), .{ .number = .{ .value = 0, .is_float = false } });
                },
                .failure => {
                    try self.recordError(.InvalidNumber, "invalid number literal", token.span());
                    break :blk self.allocExpr(token.span(), .{ .number = .{ .value = 0, .is_float = false } });
                },
            };
            const is_float = (parsed == .float);
            if (!std.math.isFinite(value))
                try self.recordError(.InvalidNumber, "number literal too large", token.span());
            break :blk self.allocExpr(token.span(), .{ .number = .{ .value = value, .is_float = is_float } });
        },
        .string => if (token.interp_opens.len > 0)
            self.parseInterpolatedString(token)
        else
            self.allocExpr(token.span(), .{ .string = token.text }),
        .multiline_string => if (token.interp_opens.len > 0)
            self.parseInterpolatedString(token)
        else
            self.allocExpr(token.span(), .{ .multiline_string = token.text }),
        .hash => self.allocExpr(token.span(), .{ .hash = token.text[1..] }),
        .doc_comment => self.parseDocAttr(token),
        .ident => self.allocExpr(token.span(), .{ .ident = token.text }),
        .kw_const, .kw_global, .kw_let, .kw_test, .kw_suite, .kw_declare => self.parseDecl(token),
        .kw_proc => self.parseProc(token),
        .kw_fn => self.parseFnWithBodyMin(token, 0),
        .minus => self.parseUnary(.negate, 60, token),
        .kw_not => self.parseUnary(.not, 35, token),
        .lparen => self.parseParenExpr(token),
        .kw_if => self.parseIf(token),
        .kw_unless => self.parseUnless(token),
        .kw_match => self.parseMatch(token, null),
        .kw_do => self.parseBlock(token),
        .kw_loop => self.parseLoop(token),
        .kw_for => self.parseFor(token),
        .kw_while => self.parseWhile(token),
        .kw_break => self.parseBreak(token),
        .kw_continue => self.parseContinue(token),
        .kw_return => blk: {
            const value = try self.parseExpression(0);
            break :blk try self.allocExpr(Span.merge(token.span(), value.span), .{ .return_expr = value });
        },
        .kw_comp => self.parseComp(token),
        .kw_import => self.parseImport(token),
        .kw_spawn => self.parseUnary(.spawn, 60, token),
        .kw_join => self.parseUnary(.join, 60, token),
        .kw_yield => blk: {
            break :blk self.allocExpr(
                token.span(),
                .{ .unary = .{ .op = .yield, .expr = try self.allocExpr(token.span(), .nil) } },
            );
        },
        .lsquiggly => self.parseTable(token),
        .kw_type => {
            if (self.check(.ident)) return self.parseDecl(token);
            return self.allocExpr(token.span(), .{ .ident = token.text });
        },
        .kw_macro => self.parseMacro(token),
        .kw_pub => self.parsePubPrefix(token),
        .backtick_string => try self.parseQuasiquote(token),
        .eof => return error.UnexpectedToken,
        .colon => blk: {
            try self.recordError(
                .UnexpectedToken,
                "':' without a following name is not a value; use ':name' for an atom",
                token.span(),
            );

            break :blk self.allocExpr(token.span(), .nil);
        },
        .attribute => self.parseAttrs(token),
        else => return error.UnexpectedToken,
    };
}

/// -, not
fn parseUnary(self: *Parser, op: ast.UnOp, right_bp: u8, token: Token) anyerror!*Node {
    const expr = try self.parseExpression(right_bp);
    return self.allocExpr(Span.merge(token.span(), expr.span), .{ .unary = .{ .op = op, .expr = expr } });
}

const AttrKind = enum { native };

const attr_table = std.StaticStringMap(AttrKind).initComptime(.{
    .{ "@native", .native },
});

const PendingAttr = struct {
    kind: AttrKind,
    span: Span,
};

fn parseAttrs(self: *Parser, first: Token) anyerror!*Node {
    var pending: std.ArrayList(PendingAttr) = .empty;
    defer pending.deinit(self.alloc);

    var token = first;
    while (true) {
        const kind = attr_table.get(token.text) orelse return error.UnknownAttribute;
        try pending.append(self.alloc, .{ .kind = kind, .span = token.span() });

        if (!self.check(.attribute)) break;
        token = self.advance();
    }

    const target = try self.parsePrefix();
    for (pending.items) |attr| {
        _ = try self.applyAttr(target, attr);
    }
    return target;
}

fn applyAttr(self: *Parser, node: *Node, attr: PendingAttr) anyerror!*Node {
    switch (node.expr) {
        .decl => return self.applyAttr(node.expr.decl.inner, attr),
        .fn_expr => {
            node.expr.fn_expr.native = true;
            return node;
        },
        .binding => |binding| {
            if (binding.value.expr != .fn_expr) return error.UnexpectedToken;
            return self.applyAttr(binding.value, attr);
        },
        .assign_expr => |assign| {
            if (assign.value.expr != .fn_expr) return error.UnexpectedToken;
            return self.applyAttr(assign.value, attr);
        },
        else => return error.UnexpectedToken,
    }
}

fn parseDocAttr(self: *Parser, doc_token: Token) anyerror!*Node {
    const target = try self.parsePrefix();
    // the lexer keeps the `#*`/`*#` padding in the token text
    const trimmed = std.mem.trim(u8, doc_token.text, " \t\n\r");
    return applyDocAttr(target, trimmed);
}

fn applyDocAttr(node: *Node, doc_text: []const u8) anyerror!*Node {
    switch (node.expr) {
        // every decl kind gets docs through this one slot
        .decl => |*d| {
            d.doc = doc_text;
            return node;
        },
        .assign_expr => {
            // method-style `fn obj:name` isn't a decl wrapper, doc rides the fn
            const value = node.expr.assign_expr.value;
            if (value.expr != .fn_expr) return error.UnexpectedToken;
            value.expr.fn_expr.doc = doc_text;
            return node;
        },
        else => return error.UnexpectedToken,
    }
}

/// fn(params) body               - anonymous function
/// fn name(params) body          - const name = fn(params) body
/// fn obj:name(params) body      - const obj.name = fn(self, params) body
fn parseFnWithBodyMin(self: *Parser, start: Token, body_min_bp: u8) anyerror!*Node {
    // is named fn def?
    if (self.check(.ident)) {
        const first_ident = self.advance();

        // `fn obj:method(params) body`, implicit self
        if (self.peek().type == .hash) {
            const atom_token = self.advance();
            const method_name = atom_token.text[1..];
            _ = try self.expect(.lparen);
            const params = try self.parseParamList(.rparen);
            _ = try self.expect(.rparen);
            const return_type = if (self.match(.arrow)) try self.parseTypeExpr() else null;
            const body = try self.parseStatementExpression(body_min_bp);

            var new_params = try self.alloc.alloc(ast.FnParam, params.len + 1);
            errdefer self.alloc.free(new_params);
            new_params[0] = .{ .name = "self", .name_span = atom_token.span() };
            @memcpy(new_params[1..], params);

            const fn_node = try self.allocExpr(Span.merge(start.span(), body.span), .{
                .fn_expr = .{ .params = new_params, .return_type = return_type, .body = body },
            });
            const obj_node = try self.allocExpr(first_ident.span(), .{ .ident = first_ident.text });
            const key_node = try self.allocExpr(atom_token.span(), .{ .hash = method_name });
            const index_node = try self.allocExpr(Span.merge(first_ident.span(), atom_token.span()), .{
                .index = .{ .object = obj_node, .key = key_node },
            });
            return self.allocExpr(Span.merge(start.span(), body.span), .{
                .assign_expr = .{ .target = index_node, .value = fn_node },
            });
        }

        // `fn obj.field(params) body`
        if (self.match(.dot)) {
            const field_name = try self.expectIdent();
            _ = try self.expect(.lparen);
            const params = try self.parseParamList(.rparen);
            _ = try self.expect(.rparen);
            const return_type = if (self.match(.arrow)) try self.parseTypeExpr() else null;
            const body = try self.parseStatementExpression(body_min_bp);

            const fn_node = try self.allocExpr(Span.merge(start.span(), body.span), .{
                .fn_expr = .{ .params = params, .return_type = return_type, .body = body },
            });
            const obj_node = try self.allocExpr(first_ident.span(), .{ .ident = first_ident.text });
            const key_node = try self.allocExpr(field_name.span(), .{ .hash = field_name.text });
            const index_node = try self.allocExpr(Span.merge(first_ident.span(), field_name.span()), .{
                .index = .{ .object = obj_node, .key = key_node },
            });
            return self.allocExpr(Span.merge(start.span(), body.span), .{
                .assign_expr = .{ .target = index_node, .value = fn_node },
            });
        }

        const type_params = if (self.match(.lbracket)) try self.parseTypeParamList() else &.{};

        if (self.check(.lparen)) {
            _ = try self.expect(.lparen);
            const params = try self.parseParamList(.rparen);
            _ = try self.expect(.rparen);
            const return_type = if (self.match(.arrow)) try self.parseTypeExpr() else null;
            const body = try self.parseStatementExpression(body_min_bp);

            const fn_node = try self.allocExpr(Span.merge(start.span(), body.span), .{
                .fn_expr = .{ .params = params, .return_type = return_type, .body = body, .type_params = type_params },
            });
            const target = try self.allocExpr(first_ident.span(), .{ .ident = first_ident.text });
            const bind_node = try self.allocExpr(Span.merge(start.span(), body.span), .{
                .binding = .{ .target = target, .value = fn_node, .mutable = false },
            });
            return self.allocExpr(
                Span.merge(start.span(), body.span),
                .{ .decl = .{ .inner = bind_node, .kind = ast.DeclKind.con } },
            );
        }
        return error.UnexpectedToken;
    }

    // anon `fn(params) body`
    _ = try self.expect(.lparen);
    const params = try self.parseParamList(.rparen);
    _ = try self.expect(.rparen);
    const return_type = if (self.match(.arrow)) try self.parseTypeExpr() else null;
    const body = try self.parseStatementExpression(body_min_bp);
    return self.allocExpr(Span.merge(start.span(), body.span), .{
        .fn_expr = .{ .params = params, .return_type = return_type, .body = body },
    });
}

fn parseComp(self: *Parser, token: Token) anyerror!*Node {
    const is_macro = self.peek().type == .kw_macro;
    if (is_macro) _ = self.advance();

    const expr = try self.parseExpression(BP.comp);
    return self.allocExpr(Span.merge(token.span(), expr.span), .{
        .comp_block = .{ .expr = expr, .is_macro = is_macro },
    });
}

/// if <expr> then <expr> else <expr>
fn parseIf(self: *Parser, start: Token) anyerror!*Node {
    const condition = try self.parseScoped(.kw_else, self.allow_bare_calls, 0);
    const then_expr = try self.parseExpression(0);
    const else_expr = if (self.match(.kw_else)) try self.parseExpression(0) else null;
    const end_span = if (else_expr) |branch| branch.span else then_expr.span;
    return self.allocExpr(Span.merge(start.span(), end_span), .{
        .if_expr = .{ .condition = condition, .then_expr = then_expr, .else_expr = else_expr },
    });
}

/// unless <expr> then <expr> else <expr>
fn parseUnless(self: *Parser, start: Token) anyerror!*Node {
    const condition = try self.parseScoped(.kw_else, self.allow_bare_calls, 0);
    const then_expr = try self.parseExpression(0);
    const else_expr = if (self.match(.kw_else)) try self.parseExpression(0) else null;
    const end_span = if (else_expr) |branch| branch.span else then_expr.span;
    return self.allocExpr(Span.merge(start.span(), end_span), .{
        .unless_expr = .{ .condition = condition, .then_expr = then_expr, .else_expr = else_expr },
    });
}

/// match expr | pat expr | pat expr
fn parseMatch(self: *Parser, start: Token, subj: ?*Node) anyerror!*Node {
    const subject = subj orelse blk: {
        if (self.check(.pipe)) {
            // synthetic `:true`
            break :blk try self.allocExpr(start.span(), .{ .hash = "true" });
        }
        break :blk try self.parseExpression(25);
    };

    var arms = try std.ArrayList(ast.MatchArm).initCapacity(self.alloc, 2);
    errdefer {
        for (arms.items) |arm| self.alloc.free(arm.matchers);
        arms.deinit(self.alloc);
    }

    var end_span = subject.span;
    while (self.match(.pipe)) {
        const arm = try self.parseMatchArm();
        end_span = arm.then.span;
        try arms.append(self.alloc, arm);
    }

    if (arms.items.len == 0) return error.ExpectedMatchArm;

    return self.allocExpr(Span.merge(start.span(), end_span), .{ .match_expr = .{
        .subject = subject,
        .arms = try arms.toOwnedSlice(self.alloc),
    } });
}

/// pat [when <expr>] => <expr>
fn parseMatchArm(self: *Parser) anyerror!ast.MatchArm {
    var matchers = try std.ArrayList(ast.MatchMatcher).initCapacity(self.alloc, 2);
    errdefer matchers.deinit(self.alloc);

    while (true) {
        if (self.checkIdentText("_")) {
            _ = self.advance();
            try matchers.append(self.alloc, .wildcard);
        } else {
            var m = try self.parseScoped(null, false, 25);
            if (self.check(.colon)) m = try self.parseAscribed(m);

            try matchers.append(self.alloc, .{
                .expr = try self.exprToPattern(m),
            });
        }
        if (!self.match(.comma)) break;
    }

    const guard = if (self.match(.kw_when)) try self.parseScoped(null, false, 25) else null;
    _ = try self.expect(.fat_arrow);

    return .{
        .matchers = try matchers.toOwnedSlice(self.alloc),
        .guard = guard,
        .then = try self.parseExpression(0),
    };
}

/// type Name = TypeExpr
fn parseTypeExpr(self: *Parser) anyerror!*ast.TypeExpr {
    return try type_serde.parse(self.tokens, &self.pos, self.alloc);
}

/// const x = expr or let x = expr, with const {a, b} = <expr> destructuring
fn parseBinding(self: *Parser, comptime kind: ast.DeclKind, start: Token) anyerror!*Node {
    const mutable: bool = switch (kind) {
        ast.DeclKind.con => false,
        ast.DeclKind.let => true,
        ast.DeclKind.global => false,
        else => @compileError("unsupported binding kind to parseBinding"),
    };

    const target: *Node = blk: {
        if (self.check(.lsquiggly)) {
            // keyless tables destructure;
            // keyed tables stay values and fail later with a proper error
            break :blk try self.exprToPattern(try self.parseTable(self.advance()));
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
                break :blk try self.allocExpr(first.span(), .{ .ident = first.text });
            }
        }
    };

    var type_name: ?*ast.TypeExpr = null;
    if (self.match(.colon)) {
        type_name = try self.parseTypeExpr();
    }
    _ = try self.expect(.assign);
    var value = try self.parseStatementExpression(0);

    // for const x = import "foo", use binding name as module name
    // so macros qualify as x.macro! instead of foo.macro!
    if (value.expr == .import_stmt and target.expr == .ident) {
        value.expr.import_stmt.name = target.expr.ident;
    }

    const span = Span.merge(start.span(), value.span);
    const binding = ast.Binding{
        .target = target,
        .value = value,
        .mutable = mutable,
        .type_name = type_name,
    };
    const binding_node = try self.allocExpr(span, .{ .binding = binding });

    return self.allocExpr(span, .{ .decl = .{ .inner = binding_node, .kind = kind } });
}

fn parseDecl(self: *Parser, start: Token) anyerror!*Node {
    return switch (start.type) {
        .kw_const => {
            return try self.parseBinding(.con, start);
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
            var skip = false;
            if (self.match(.slash)) {
                if (self.check(.kw_skip)) {
                    skip = true;
                    _ = self.advance();
                } else return error.UnexpectedToken;
            }
            const name = try self.expect(.string);
            const body_start = try self.expect(.kw_do);
            const body = try self.parseBlock(body_start);
            const body_fn = try self.allocExpr(Span.merge(body_start.span(), body.span), .{
                .fn_expr = .{ .params = &.{}, .body = body },
            });
            const node = try self.allocExpr(Span.merge(start.span(), body.span), .{
                .test_block = .{ .name = name.text, .body = body_fn, .skip = skip },
            });
            break :blk self.allocExpr(start.span(), .{ .decl = .{ .inner = node, .kind = ast.DeclKind.test_decl } });
        },
        .kw_suite => blk: {
            const name = try self.expect(.string);
            const body_start = try self.expect(.kw_do);
            const body = try self.parseBlock(body_start);
            const body_fn = try self.allocExpr(Span.merge(body_start.span(), body.span), .{
                .fn_expr = .{ .params = &.{}, .body = body },
            });
            const node = try self.allocExpr(Span.merge(start.span(), body.span), .{
                .test_suite = .{ .name = name.text, .body = body_fn },
            });
            break :blk self.allocExpr(start.span(), .{ .decl = .{ .inner = node, .kind = ast.DeclKind.suite_decl } });
        },
        .kw_type => blk: {
            if (!self.check(.ident)) return error.UnexpectedToken;
            const first = try self.expectIdent();
            const hh = try self.parseDeclareHead(first, false);

            _ = try self.expect(.assign);
            const type_expr = try self.parseTypeExpr();

            const node = try self.allocExpr(Span.merge(start.span(), type_expr.span), .{
                .type_alias = .{
                    .name = first.text,
                    .name_span = first.span(),
                    .type_expr = type_expr,
                    .declare_head = hh.head,
                    .declare_tps = hh.tps,
                },
            });
            break :blk self.allocExpr(
                start.span(),
                .{ .decl = .{ .inner = node, .kind = ast.DeclKind.type_alias_decl } },
            );
        },
        .kw_declare => blk: {
            // bodge: `type`, `import`, `join` are stdlib globals, usable as names
            if (!self.check(.ident)) switch (self.peek().type) {
                .kw_type, .kw_import, .kw_join => {},
                else => return error.UnexpectedToken,
            };
            const first = self.advance();
            const hh = try self.parseDeclareHead(first, true);

            _ = try self.expect(.assign);
            const type_expr = try self.parseTypeExpr();

            const node = try self.allocExpr(Span.merge(start.span(), type_expr.span), .{
                .type_alias = .{
                    .name = first.text,
                    .name_span = first.span(),
                    .type_expr = type_expr,
                    .declare_head = hh.head,
                    .declare_tps = hh.tps,
                },
            });
            break :blk self.allocExpr(
                start.span(),
                // declares are pub by default; `pub declare` still parses
                .{ .decl = .{ .inner = node, .kind = ast.DeclKind.declare_decl, .pub_ = true } },
            );
        },
        else => return error.UnexpectedToken,
    };
}

/// shared `Name`, `Target:key`, `a.b.c`, `[T]`, etc. for `declare` and `type`
///   so that dotted type heads parse identically
///
/// `allow_core` is false for `type`:: metatable slots are values, not types.
fn parseDeclareHead(self: *Parser, first: Token, allow_core: bool) !struct { head: ?ast.DeclareHead, tps: []const []const u8 } {
    // peek first so a rejected core head leaves no partial consumption
    if (!allow_core and (self.check(.hash) or self.check(.colon))) return error.UnexpectedToken;
    var head: ?ast.DeclareHead = null;
    if (self.check(.hash)) {
        // `string:__index`
        //   the lexer merges `:` + key into one hash
        const key = self.advance();
        head = .{ .core = .{ .target = first.text, .key = key.text[1..] } };
    } else if (self.match(.colon)) {
        // `string:__index`
        //   a core-key slot on a target type
        const key = try self.expectIdent();
        head = .{ .core = .{ .target = first.text, .key = key.text } };
    } else if (self.check(.dot)) {
        // `fs.open`, `uri.Hi`
        //   a dotted module path
        var segs = std.ArrayList([]const u8).initCapacity(self.alloc, 2) catch return error.OutOfMemory;
        try segs.append(self.alloc, first.text);
        while (self.match(.dot)) {
            const seg = try self.expectIdent();
            try segs.append(self.alloc, seg.text);
        }

        head = .{ .module = try segs.toOwnedSlice(self.alloc) };
    }
    const tps = if (self.match(.lbracket)) try self.parseTypeParamList() else &.{};
    return .{ .head = head, .tps = tps };
}

fn parseOptionalLabel(self: *Parser) ?[]const u8 {
    if (self.match(.slash)) {
        if (!self.tokenAdjacent(self.tokens[self.pos - 1].span().end)) {
            self.pos -= 1;
            return null;
        }
        const ident = self.expectIdent() catch {
            self.pos -= 1;
            return null;
        };
        return ident.text;
    }
    return null;
}

/// loop do expr end
fn parseLoop(self: *Parser, start: Token) anyerror!*Node {
    const label = self.parseOptionalLabel();
    const body = try self.parseExpression(0);
    return self.allocExpr(
        Span.merge(start.span(), body.span),
        .{ .loop_expr = .{ .body = body, .label = label } },
    );
}

/// while <cond> <expr>
fn parseWhile(self: *Parser, start: Token) anyerror!*Node {
    const label = self.parseOptionalLabel();
    const predicate = try self.parseExpression(25);
    const body = try self.parseExpression(0);
    return self.allocExpr(Span.merge(start.span(), body.span), .{
        .while_loop = .{ .predicate = predicate, .body = body, .label = label },
    });
}

fn parseFor(self: *Parser, start: Token) anyerror!*Node {
    const label = self.parseOptionalLabel();
    var params = try std.ArrayList(ast.FnParam).initCapacity(self.alloc, 2);
    errdefer params.deinit(self.alloc);
    const first = try self.expectIdent();
    try params.append(self.alloc, .{ .name = first.text, .name_span = first.span() });
    while (self.match(.comma)) {
        const name = try self.expectIdent();
        try params.append(self.alloc, .{ .name = name.text, .name_span = name.span() });
    }
    _ = try self.expect(.kw_in);

    const iter = try self.parseForRange();
    const body = try self.parseExpression(0);
    return self.allocExpr(Span.merge(start.span(), body.span), .{
        .for_loop = .{ .params = try params.toOwnedSlice(self.alloc), .iter = iter, .body = body, .label = label },
    });
}

/// range expr in a for-loop context
///   ..5, 0.., 0..5, 0..2..10, 0..2..
/// a missing end is represented as +/-inf so the vm never terminates on its own
/// adjacency rule: `..` must touch the next token for it to be part of the range;
/// a space after `..` means the range is open-ended and the next token starts the body
fn parseForRange(self: *Parser) anyerror!*Node {
    const zero = try self.allocExpr(self.peek().span(), .{ .number = .{ .value = 0 } });
    const one = try self.allocExpr(self.peek().span(), .{ .number = .{ .value = 1 } });

    if (self.check(.dotdot)) {
        const tok = self.advance();
        return self.parseForRangeEnd(zero, one, tok.span().end);
    }

    const first = scope: {
        const prev_stop = self.stop_token;
        self.stop_token = .dotdot;
        defer self.stop_token = prev_stop;
        break :scope try self.parseExpression(0);
    };

    if (!self.match(.dotdot)) return first;

    return self.parseForRangeEnd(first, one, self.tokens[self.pos - 1].span().end);
}

/// After `start..` (or `..` with synthesized start), check adjacency to decide
/// whether the next token is the range end, the step (if followed by another `..`),
/// or the loop body (open-ended range).
fn parseForRangeEnd(self: *Parser, start: *Node, default_step: *Node, dotdot_end: usize) anyerror!*Node {
    if (!self.tokenAdjacent(dotdot_end)) {
        const end = try self.allocExpr(self.peek().span(), .{ .number = .{ .value = sentinelForStep(default_step) } });
        return self.buildRangeExpr(start, end, default_step);
    }

    const expr = scope: {
        const prev_stop = self.stop_token;
        self.stop_token = .dotdot;
        defer self.stop_token = prev_stop;
        break :scope try self.parseExpression(0);
    };

    if (self.match(.dotdot)) {
        const second_dd_end = self.tokens[self.pos - 1].span().end;
        if (!self.tokenAdjacent(second_dd_end)) {
            const end = try self.allocExpr(self.peek().span(), .{ .number = .{ .value = sentinelForStep(expr) } });
            return self.buildRangeExpr(start, end, expr);
        }
        const end = try self.parseExpression(0);
        return self.buildRangeExpr(start, end, expr);
    }

    const step = try self.allocExpr(expr.span, .{ .number = .{ .value = 1 } });
    return self.buildRangeExpr(start, expr, step);
}

/// +inf for positive step, -inf for negative step (so range_loop never terminates)
fn sentinelForStep(step: *const Node) f64 {
    const val = switch (step.expr) {
        .number => step.expr.number.value,
        .unary => |u| if (u.op == .negate and u.expr.expr == .number)
            -u.expr.expr.number.value
        else
            return std.math.inf(f64),

        else => return std.math.inf(f64),
    };
    if (val < 0) return -std.math.inf(f64);
    return std.math.inf(f64);
}

/// true when the next token immediately follows the given position (no whitespace gap)
fn tokenAdjacent(self: *Parser, prev_end: usize) bool {
    if (self.pos >= self.tokens.len) return false;
    return self.peek().span().start == prev_end;
}

fn parseBreak(self: *Parser, start: Token) anyerror!*Node {
    const label = self.parseOptionalLabel();
    const value = try self.parseExpression(0);
    return self.allocExpr(Span.merge(start.span(), value.span), .{
        .break_expr = .{ .value = value, .label = label },
    });
}

fn parseContinue(self: *Parser, start: Token) anyerror!*Node {
    const label = self.parseOptionalLabel();
    return self.allocExpr(start.span(), .{
        .continue_expr = .{ .value = null, .label = label },
    });
}

/// pub prefix on declarations
fn parsePubPrefix(self: *Parser, _: Token) anyerror!*Node {
    const pub_keywords = comptime [_]TokenType{
        .kw_const,
        .kw_let,
        .kw_fn,
        .kw_test,
        .kw_suite,
        .kw_proc,
        .kw_type,
        .kw_macro,
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

    // TODO: import and macro are not decl nodes
    if (decl_start.type == .kw_import) {
        var node = try self.parseImport(decl_start);
        if (node.expr == .import_stmt) {
            node.expr.import_stmt.pub_ = true;
        } else if (node.expr == .block) {
            for (node.expr.block) |item| {
                if (item.expr == .import_stmt) item.expr.import_stmt.pub_ = true;
            }
        }
        return node;
    }

    if (decl_start.type == .kw_macro) {
        const node = try self.parseMacro(decl_start);
        return self.allocExpr(node.span, .{ .decl = .{ .inner = node, .kind = .con, .pub_ = true } });
    }

    if (decl_start.type == .kw_proc) {
        const node = try self.parseProc(decl_start);
        return self.allocExpr(node.span, .{ .decl = .{ .inner = node, .kind = .con, .pub_ = true } });
    }

    var node = try self.parseDecl(decl_start);
    if (node.expr == .decl) node.expr.decl.pub_ = true;
    return node;
}

/// import "path" or import { ... }
fn parseImport(self: *Parser, start: Token) anyerror!*Node {
    // import { m1 = "mod1", "mod2" }
    if (self.peek().type == .lsquiggly) {
        _ = try self.expect(.lsquiggly);
        var import_nodes = try std.ArrayList(*Node).initCapacity(self.alloc, 4);

        while (self.peek().type != .rsquiggly) {
            if (self.peek().type == .string) {
                // "path", auto-bind
                const path_token = try self.expect(.string);
                const name = try self.alloc.dupe(u8, std.fs.path.stem(path_token.text));
                try import_nodes.append(self.alloc, try self.allocExpr(
                    Span.merge(start.span(), path_token.span()),
                    .{ .import_stmt = .{ .name = name, .path = path_token.text } },
                ));
            } else {
                // ident = "path", custom name
                const name_token = try self.expect(.ident);
                _ = try self.expect(.assign);
                const path_token = try self.expect(.string);
                try import_nodes.append(self.alloc, try self.allocExpr(
                    Span.merge(start.span(), path_token.span()),
                    .{ .import_stmt = .{ .name = name_token.text, .path = path_token.text } },
                ));
            }
            if (self.peek().type != .rsquiggly) _ = try self.expect(.comma);
        }
        _ = try self.expect(.rsquiggly);

        const blk = try self.allocExpr(start.span(), .{ .block = try import_nodes.toOwnedSlice(self.alloc) });
        blk.synthetic_block = true;
        return blk;
    }

    // import "path" autobind
    {
        const path_token = try self.expect(.string);
        const name = try self.alloc.dupe(
            u8,
            if (std.mem.endsWith(u8, path_token.text, ".d.rv"))
                path_token.text[0 .. path_token.text.len - ".d.rv".len]
            else
                std.fs.path.stem(path_token.text),
        );
        return self.allocExpr(
            Span.merge(start.span(), path_token.span()),
            .{ .import_stmt = .{ .name = name, .path = path_token.text } },
        );
    }
}
/// quasiquote `(expr with %splices)`
fn parseQuasiquote(self: *Parser, token: Token) anyerror!*Node {
    const raw = token.text;
    var splice_count: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%' and i + 1 < raw.len and lexer.isIdentStart(raw[i + 1])) {
            splice_count += 1;
            i += 1;
            while (i < raw.len and lexer.isIdentContinue(raw[i])) i += 1;
        } else i += 1;
    }

    var modified = try std.ArrayList(u8).initCapacity(self.alloc, raw.len);
    var splices = try std.ArrayList([]const u8).initCapacity(self.alloc, splice_count);

    i = 0;
    var counter: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%' and i + 1 < raw.len and lexer.isIdentStart(raw[i + 1])) {
            i += 1;
            const start = i;
            while (i < raw.len and lexer.isIdentContinue(raw[i])) i += 1;
            try splices.append(self.alloc, raw[start..i]);
            try modified.appendSlice(self.alloc, "__qq_");
            var buf: [32]u8 = undefined;
            try modified.appendSlice(self.alloc, try std.fmt.bufPrint(&buf, "{d}", .{counter}));
            counter += 1;
        } else {
            try modified.append(self.alloc, raw[i]);
            i += 1;
        }
    }

    // parse tmpl with origin at backtick token so inner node
    // spans land in real src coords
    // `%x` -> `__qq_N` rewrites shift
    // byte offsets after first splice, so those are approx
    const inner = try parseTokens(self.alloc, try lexer.lexAt(self.alloc, modified.items, .{
        .offset = token.start + 1,
        .line = token.line,
        .column = token.column + 1,
    }));
    return self.allocExpr(token.span(), .{ .quasiquote = .{
        .inner = inner,
        .splices = try splices.toOwnedSlice(self.alloc),
    } });
}

/// macro name! `pattern` `template`
/// `name!` or single-scoped `mod.name!`; deeper nesting cant expand
/// (calls only resolve one field level)
/// , core slots are values not macros
fn parseMacroHead(self: *Parser, first: Token) ![]const u8 {
    if (self.check(.hash) or self.check(.colon)) return error.UnexpectedToken;
    if (!self.match(.dot)) return first.text;
    const seg = try self.expectIdent();

    if (self.check(.dot)) return error.UnexpectedToken;
    return try std.mem.join(self.alloc, ".", &.{ first.text, seg.text });
}

fn parseMacro(self: *Parser, start: Token) anyerror!*Node {
    if (!self.check(.ident)) return error.UnexpectedToken;
    const name = try self.parseMacroHead(self.advance());
    if (!std.mem.endsWith(u8, name, "!")) return error.InvalidMacroName;

    const pattern = try self.expect(.backtick_string);
    const template = try self.expect(.backtick_string);

    return self.allocExpr(Span.merge(start.span(), template.span()), .{ .macro_expr = .{
        .name = name,
        .pattern = pattern.text,
        .template = template.text,
    } });
}

/// proc name(param) body
/// no anonymous procs
fn parseProc(self: *Parser, start: Token) anyerror!*Node {
    // check if this is a named function definition
    if (!self.check(.ident)) return error.AnonProc;
    const first_ident = self.advance();
    const macro_name = try self.parseMacroHead(first_ident);
    if (!std.mem.endsWith(u8, macro_name, "!")) return error.InvalidProcName;

    if (self.check(.lparen)) {
        _ = try self.expect(.lparen);

        const name = try self.expectIdent();
        const param: ast.FnParam = .{ .name = name.text, .name_span = name.span() };
        _ = try self.expect(.rparen);
        const body = try self.parseExpression(0);

        return try self.allocExpr(Span.merge(start.span(), body.span), .{
            .proc_macro = .{ .param = param, .body = body, .name = macro_name },
        });
    }

    return error.UnexpectedToken;
}

/// do expr end
fn parseBlock(self: *Parser, start: Token) anyerror!*Node {
    if (self.match(.slash)) {
        const ident = try self.expectIdent();
        const body = try self.parseDoBody();
        body.span = Span.merge(start.span(), body.span);
        return self.allocExpr(Span.merge(start.span(), body.span), .{
            .labeled_block = .{ .label = ident.text, .body = body },
        });
    }
    const body = try self.parseDoBody();
    body.span = Span.merge(start.span(), body.span);
    return body;
}

/// { key = value, [expr] = value, value, ... }
fn parseTable(self: *Parser, start: Token) anyerror!*Node {
    var entries = try std.ArrayList(ast.TableEntry).initCapacity(self.alloc, 4);
    errdefer entries.deinit(self.alloc);
    var end_span = start.span();

    while (!self.check(.rsquiggly)) {
        if (self.match(.lbracket)) {
            const computed_key = try self.parseExpression(0);
            _ = try self.expect(.rbracket);
            _ = try self.expect(.assign);
            const keyed_value = try self.parseExpression(0);
            end_span = keyed_value.span;
            try entries.append(
                self.alloc,
                .{ .key = computed_key, .computed = true, .value = keyed_value },
            );
            if (!self.match(.comma)) break;
            continue;
        }

        const first = try self.parseExpression(6);
        if (self.match(.assign)) {
            const keyed_value = try self.parseExpression(0);
            end_span = keyed_value.span;
            try entries.append(self.alloc, .{ .key = first, .value = keyed_value });
        } else if (self.check(.colon)) {
            const asc = try self.parseAscribed(first);
            end_span = asc.span;

            try entries.append(self.alloc, .{ .key = null, .value = asc });
        } else {
            end_span = first.span;
            try entries.append(self.alloc, .{ .key = null, .value = first });
        }

        if (!self.match(.comma)) break;
    }

    const close = try self.expect(.rsquiggly);
    return self.allocExpr(
        Span.merge(start.span(), if (entries.items.len == 0) close.span() else end_span),
        .{ .table = try entries.toOwnedSlice(self.alloc) },
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
    try testing_helpers.expectPrinted(
        "{ [a] = 5, \"b\" = 6, c = 7 }",
        "(table (entry[ a] 5) (entry \"b\" 6) (entry c 7))",
    );
}

test "parser test block parses" {
    try testing_helpers.expectPrinted(
        \\test "smoke" do
        \\    ok!
        \\end
    , "(test smoke (fn () (block ok!)))");
}

/// (expr) or (). `()` is nil
fn parseParenExpr(self: *Parser, start: Token) anyerror!*Node {
    if (self.match(.rparen)) return self.allocExpr(Span.merge(start.span(), self.tokens[self.pos - 1].span()), .nil);

    const first = try self.parseExpression(0);
    if (!self.match(.comma)) {
        _ = try self.expect(.rparen);
        return first;
    }

    try self.recordError(
        .UnexpectedToken,
        "unexpected `,` in parens, use `{...}` for tables",
        self.peek().span(),
    );
    return error.UnexpectedToken;
}

/// `expr: Type` ascription, only legal in match patterns
///   ; value positions reject it later with a proper error
fn parseAscribed(self: *Parser, first: *Node) anyerror!*Node {
    _ = try self.expect(.colon);
    const type_name = try type_serde.parse(self.tokens, &self.pos, self.alloc);

    return self.allocExpr(
        Span.merge(first.span, type_name.span),
        .{ .ascribed = .{ .expr = first, .type_name = type_name } },
    );
}

/// turn expression into pattern: keyless `{...}` tables become array
/// patterns, keyed tables stay values and fail later with a proper error
fn exprToPattern(self: *Parser, expr: *Node) anyerror!*Node {
    return switch (expr.expr) {
        .table => |entries| blk: {
            for (entries) |entry| if (entry.key != null or entry.computed) break :blk expr;
            var out = try std.ArrayList(*Node).initCapacity(self.alloc, entries.len);
            errdefer out.deinit(self.alloc);

            for (entries) |entry| try out.append(self.alloc, try self.exprToPattern(entry.value));
            break :blk try self.allocExpr(expr.span, .{ .table_pattern = try out.toOwnedSlice(self.alloc) });
        },
        .ascribed => |a| blk: {
            const inner = try self.exprToPattern(a.expr);

            break :blk try self.allocExpr(expr.span, .{ .ascribed = .{ .expr = inner, .type_name = a.type_name } });
        },
        else => expr,
    };
}

/// check if expr can be followed by bare call which is string table literal
fn isBareCallArgumentStart(self: *Parser, callee: *Node) bool {
    if (!exprAllowsBareCall(callee)) return false;
    if (self.stop_on_stmt_start and callee.span.line != self.peek().line) return false;
    return bare_call_arg_start_tokens.get(self.peek().type);
}

/// params: name, name: type, ...
fn parseParamList(self: *Parser, terminator: TokenType) anyerror![]ast.FnParam {
    var params = try std.ArrayList(ast.FnParam).initCapacity(self.alloc, 4);
    errdefer params.deinit(self.alloc);

    while (!self.check(terminator)) {
        const optional = self.match(.huh);
        const name = try self.expectIdent();
        var param: ast.FnParam = .{ .name = name.text, .name_span = name.span(), .optional = optional };
        if (self.match(.colon)) param.type_name = try self.parseTypeExpr();
        if (self.match(.assign)) param.default_value = try self.parseExpression(0);
        try params.append(self.alloc, param);
        if (!self.match(.comma)) break;
    }

    return params.toOwnedSlice(self.alloc);
}

/// do ... end: parse expressions until kw_end
fn parseDoBody(self: *Parser) anyerror!*Node {
    const exprs = try self.parseExprListUntil(.kw_end);
    const close = try self.expect(.kw_end);
    return self.allocExpr(ast.spanFromNodes(exprs, close.span()), .{ .block = exprs });
}

/// parse with stop token and optional bare-call setting
fn parseScoped(self: *Parser, stop: ?TokenType, allow_bare_calls: bool, min_bp: u8) anyerror!*Node {
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

/// statements are defers n such
fn parseStatementExpression(self: *Parser, min_bp: u8) anyerror!*Node {
    const prev_stop_on_stmt_start = self.stop_on_stmt_start;
    self.stop_on_stmt_start = true;
    defer self.stop_on_stmt_start = prev_stop_on_stmt_start;
    return self.parseExpression(min_bp);
}

/// exprs until terminator (for block body, match arms, etc)
/// TODO: defer goes here
fn parseExprListUntil(self: *Parser, terminator: TokenType) anyerror![]*Node {
    var exprs = try std.ArrayList(*Node).initCapacity(self.alloc, 4);
    errdefer exprs.deinit(self.alloc);

    while (!self.check(terminator) and !self.check(.eof)) {
        while (self.match(.semicolon)) {}
        if (self.check(terminator) or self.check(.eof)) break;
        const start_pos = self.pos;
        const expr = self.parseStatementExpression(0) catch |err| switch (err) {
            error.UnexpectedToken, error.ExpectedIdentifier, error.ExpectedMatchArm => {
                try self.recordSyntaxError(err, self.peek());
                self.syncToNextStatement(terminator);
                if (self.pos == start_pos) self.pos = @min(self.pos + 1, self.tokens.len - 1);
                continue;
            },
            else => return err,
        };
        try exprs.append(self.alloc, expr);
        if (self.pos >= self.tokens.len) break;
    }

    return exprs.toOwnedSlice(self.alloc);
}

/// args: expr, expr, ... (comma separated, stops at terminator)
fn parseDelimitedExprList(self: *Parser, terminator: TokenType) anyerror![]*Node {
    var items = try std.ArrayList(*Node).initCapacity(self.alloc, 2);
    errdefer items.deinit(self.alloc);

    while (!self.check(terminator) and !self.check(.eof)) {
        const item = self.parseExpression(0) catch |err| switch (err) {
            error.UnexpectedToken, error.ExpectedIdentifier, error.ExpectedMatchArm => {
                try self.recordSyntaxError(err, self.peek());
                self.syncToNextStatement(terminator);
                if (self.check(.eof)) break;
                continue;
            },
            else => return err,
        };
        try items.append(self.alloc, item);
        if (self.pos >= self.tokens.len) break;
        if (!self.match(.comma)) break;
    }

    return items.toOwnedSlice(self.alloc);
}

/// Parse the key expression inside brackets, handling slice syntax with
/// open bounds: [..], [..end], [start..], [start..end], [start..step..end].
fn parseBracketKey(self: *Parser) anyerror!*Node {
    if (self.peek().type == .dotdot) {
        _ = self.advance();
        return self.parseSliceRest(null, null);
    }

    const first = scope: {
        const prev_stop = self.stop_token;
        self.stop_token = .dotdot;
        defer self.stop_token = prev_stop;
        break :scope try self.parseExpression(0);
    };

    if (self.match(.dotdot)) {
        return self.parseSliceRest(first, null);
    }
    return first;
}

/// After consuming the first `..`, parse the remainder of a slice literal.
/// `start` is null if omitted, `seen_step` is null if no step has been parsed yet.
fn parseSliceRest(self: *Parser, start: ?*Node, seen_step: ?*Node) anyerror!*Node {
    if (self.check(.rbracket)) {
        return self.allocSliceExpr(start, seen_step, null);
    }

    const expr = scope: {
        const prev_stop = self.stop_token;
        self.stop_token = .dotdot;
        defer self.stop_token = prev_stop;
        break :scope try self.parseExpression(BP.range);
    };

    if (self.match(.dotdot)) {
        return self.parseSliceRest(start, expr);
    }
    return self.allocSliceExpr(start, seen_step, expr);
}

fn parseTypeParamList(self: *Parser) ![]const []const u8 {
    var tps = try std.ArrayList([]const u8).initCapacity(self.alloc, 2);
    errdefer tps.deinit(self.alloc);
    while (!self.check(.rbracket)) {
        const tp = try self.expectIdent();
        try tps.append(self.alloc, tp.text);
        if (!self.match(.comma)) break;
    }
    _ = try self.expect(.rbracket);
    return tps.toOwnedSlice(self.alloc);
}

fn allocSliceExpr(self: *Parser, start: ?*Node, step: ?*Node, end: ?*Node) anyerror!*Node {
    const span = Span.merge(
        if (start) |s| s.span else self.peek().span(),
        if (end) |e| e.span else self.peek().span(),
    );
    return self.allocExpr(span, .{
        .slice_literal = .{ .start = start, .step = step, .end = end },
    });
}

/// 0.. and 0..10 :== {:range, 0, 1, limit(int)} and {:range, 0, 1, 10}
fn buildRangeExpr(self: *Parser, start: *Node, end: *Node, step: *Node) anyerror!*Node {
    const span = Span.merge(start.span, end.span); // covers start..[step..]end
    return self.allocExpr(span, .{
        .range_literal = .{ .start = start, .step = step, .end = end },
    });
}

fn recordSyntaxError(self: *Parser, err: anyerror, token: Token) !void {
    const kind: Kind = switch (err) {
        error.UnexpectedToken => .UnexpectedToken,
        error.ExpectedIdentifier => .ExpectedIdentifier,
        error.ExpectedMatchArm => .ExpectedMatchArm,
        else => return err,
    };
    const message: []const u8 = switch (err) {
        error.UnexpectedToken => "unexpected token",
        error.ExpectedIdentifier => "expected identifier",
        error.ExpectedMatchArm => "match expression requires at least one arm",
        else => return err,
    };
    try self.recordError(kind, message, token.span());
}

// peek without consuming
fn check(self: *Parser, kind: TokenType) bool {
    return self.peek().type == kind;
}

fn match(self: *Parser, kind: TokenType) bool {
    if (!self.check(kind)) return false;
    self.pos += 1;
    return true;
}

/// consume token or error: expected kind
fn expect(self: *Parser, kind: TokenType) error{UnexpectedToken}!Token {
    const token = self.peek();
    if (token.type != kind) return error.UnexpectedToken;
    self.pos += 1;
    return token;
}

/// consume identifier or keyword
fn expectIdent(self: *Parser) error{ExpectedIdentifier}!Token {
    const token = self.peek();
    if (token.type != .ident and !std.mem.startsWith(u8, @tagName(token.type), "kw_"))
        return error.ExpectedIdentifier;
    self.pos += 1;
    return token;
}

/// consume and return current token, advance pos
fn advance(self: *Parser) Token {
    const token = self.peek();
    self.pos += 1;
    return token;
}

/// peek current token without consuming; skips comment tokens
fn peek(self: *Parser) Token {
    while (self.pos < self.tokens.len and (self.tokens[self.pos].type == .comment or self.tokens[self.pos].type == .module_doc)) {
        self.pos += 1;
    }
    return self.tokens[@min(self.pos, self.tokens.len - 1)];
}

/// peek token at offset without consuming; skips comment tokens
fn peekAt(self: *Parser, offset: usize) Token {
    var p = self.pos;
    while (p < self.tokens.len and (self.tokens[p].type == .comment or self.tokens[p].type == .module_doc)) {
        p += 1;
    }
    var i: usize = 0;
    while (i < offset) {
        p += 1;
        while (p < self.tokens.len and (self.tokens[p].type == .comment or self.tokens[p].type == .module_doc)) {
            p += 1;
        }
        i += 1;
    }
    return self.tokens[@min(p, self.tokens.len - 1)];
}

/// peek identifier and check text match
fn checkIdentText(self: *Parser, text: []const u8) bool {
    const token = self.peek();
    return token.type == .ident and std.mem.eql(u8, token.text, text);
}

fn isStatementBoundary(self: *Parser, left: *const Node) bool {
    if (self.looksLikeParenAssignStart()) return true;
    if (self.forcesStatementBoundary(left, self.peek().type)) return true;
    if (!expr_start_tokens.get(self.peek().type)) return false;
    return !self.canContinueExpression(left);
}

fn forcesStatementBoundary(self: *Parser, left: *const Node, next: TokenType) bool {
    return switch (left.expr) {
        .number => next == .lparen and !self.tokenAdjacent(left.span.end),
        .decl => expr_start_tokens.get(next),
        .assign_expr, .compound_assign, .return_expr, .break_expr, .continue_expr, .labeled_block => expr_start_tokens.get(next),
        .call => call_stmt_boundary_tokens.get(next),
        else => false,
    };
}

fn canContinueExpression(self: *Parser, left: *const Node) bool {
    const t = self.peek().type;
    if (t == .dot or t == .lbracket or t == .assign or t == .dotdot or t == .pipe_forward or t == .hash) return true;
    if (t == .plus_assign or t == .minus_assign or t == .star_assign or
        t == .slash_assign or t == .percent_assign or t == .caret_assign or
        t == .concat_assign) return true;

    if (logical_binding_table.get(t) != null) return true;
    if (infix_binding_table.get(t) != null) return true;
    if (t == .lparen and (exprAllowsParenCall(left) or self.tokenAdjacent(left.span.end))) return true;
    if (t == .hash and self.peekAt(1).type == .lparen) return true;
    if (self.allow_bare_calls and exprAllowsBareCall(left)) return bare_call_arg_start_tokens.get(t);
    return false;
}

fn looksLikeParenAssignStart(self: *Parser) bool {
    if (!self.stop_on_stmt_start or !self.check(.lparen)) return false;

    var i: usize = self.pos;
    var depth: u32 = 0;
    while (i < self.tokens.len) : (i += 1) {
        const t = self.tokens[i].type;
        if (t == .lparen) {
            depth += 1;
        } else if (t == .rparen) {
            if (depth == 0) return false;
            depth -= 1;
            if (depth == 0) {
                if (i + 1 >= self.tokens.len) return false;
                return self.tokens[i + 1].type == .assign;
            }
        } else if (t == .eof) return false;
    }
    return false;
}

/// alloc node and set span+expr
fn allocExpr(self: *Parser, span: Span, expr: Expr) anyerror!*Node {
    const node = try self.alloc.create(Node);
    node.* = .{ .span = span, .expr = expr };
    return node;
}

fn desugarPipe(self: *Parser, left: *Node, right: *Node) anyerror!*Node {
    if (ast.hasUnderscore(right)) return self.wrapPipeLexical(left, right);

    return switch (right.expr) {
        .ident, .fn_expr => {
            if (left.expr == .block) return self.wrapPipeCallWithTemp(left, right, &.{}, false);
            const args = try self.alloc.alloc(*Node, 1);
            errdefer self.alloc.free(args);
            args[0] = left;
            return self.allocExpr(Span.merge(left.span, right.span), .{ .call = .{
                .callee = right,
                .args = args,
            } });
        },
        .call => |call| {
            if (left.expr == .block) return self.wrapPipeCallWithTemp(left, call.callee, call.args, call.implicit_self);
            const call_args = try self.alloc.alloc(*Node, call.args.len + 1);
            errdefer self.alloc.free(call_args);
            call_args[0] = left;
            @memcpy(call_args[1..], call.args);
            return self.allocExpr(Span.merge(left.span, right.span), .{ .call = .{
                .callee = call.callee,
                .args = call_args,
                .implicit_self = call.implicit_self,
            } });
        },
        // the rhs was an infix chain without a placeholder, the pipe binds
        // tighter than infix, so plug the piped value into the leftmost
        // operand, keeping `x |> f() ~ z` == `(x |> f()) ~ z`
        .binary => |bin| {
            const left_plug = try self.desugarPipe(left, bin.left);
            return self.allocExpr(Span.merge(left.span, right.span), .{
                .binary = .{ .op = bin.op, .left = left_plug, .right = bin.right },
            });
        },
        else => self.wrapPipeLexical(left, right),
    };
}

fn wrapPipeCallWithTemp(
    self: *Parser,
    left: *Node,
    callee: *Node,
    args: []const *Node,
    implicit_self: bool,
) anyerror!*Node {
    const temp_target = try self.allocExpr(left.span, .{ .ident = pipe_temp_name });
    const temp_ref = try self.allocExpr(left.span, .{ .ident = pipe_temp_name });
    const binding: ast.Binding = .{ .target = temp_target, .value = left };
    const bind = try self.allocExpr(left.span, .{ .decl = .{
        .inner = try self.allocExpr(left.span, .{ .binding = binding }),
        .kind = ast.DeclKind.con,
    } });

    const call_args = try self.alloc.alloc(*Node, args.len + 1);
    errdefer self.alloc.free(call_args);
    call_args[0] = temp_ref;
    @memcpy(call_args[1..], args);
    const call = try self.allocExpr(Span.merge(left.span, callee.span), .{ .call = .{
        .callee = callee,
        .args = call_args,
        .implicit_self = implicit_self,
    } });

    const exprs = try self.alloc.alloc(*Node, 2);
    errdefer self.alloc.free(exprs);
    exprs[0] = bind;
    exprs[1] = call;
    return self.allocExpr(Span.merge(left.span, callee.span), .{ .block = exprs });
}

fn wrapPipeLexical(self: *Parser, left: *Node, right: *Node) anyerror!*Node {
    const underscore = try self.allocExpr(left.span, .{ .ident = "_" });
    const binding: ast.Binding = .{ .target = underscore, .value = left };
    const bind = try self.allocExpr(left.span, .{ .decl = .{
        .inner = try self.allocExpr(left.span, .{ .binding = binding }),
        .kind = ast.DeclKind.con,
    } });
    const exprs = try self.alloc.alloc(*Node, 2);
    errdefer self.alloc.free(exprs);
    exprs[0] = bind;
    exprs[1] = right;
    return self.allocExpr(Span.merge(left.span, right.span), .{ .block = exprs });
}

const pipe_temp_name = "_";

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
    // right-assoc to match lua
    table.set(.concat, .{ .left = 41, .right = 40, .op = .concat });
    table.set(.minus, .{ .left = 40, .right = 41, .op = .sub });
    table.set(.star, .{ .left = 50, .right = 51, .op = .mul });
    table.set(.slash, .{ .left = 50, .right = 51, .op = .div });
    table.set(.slash_slash, .{ .left = 50, .right = 51, .op = .int_div });
    table.set(.percent, .{ .left = 50, .right = 51, .op = .mod });
    // exponent: right-assoc, binds tighter than unary minus (python: -2^2 == -4)
    table.set(.caret, .{ .left = 62, .right = 61, .op = .pow });
    // bitwise; C-ish precedence: shifts bind tightest, then band, bxor, bor
    table.set(.kw_shl, .{ .left = 48, .right = 49, .op = .shl });
    table.set(.kw_shr, .{ .left = 48, .right = 49, .op = .shr });
    table.set(.kw_band, .{ .left = 44, .right = 45, .op = .band });
    table.set(.kw_bxor, .{ .left = 43, .right = 44, .op = .bxor });
    table.set(.kw_bor, .{ .left = 42, .right = 43, .op = .bor });
    break :blk table;
};

const InterpolationMode = enum { display, debug, pretty };

fn interpolationMode(suffix: []const u8) ?InterpolationMode {
    if (suffix.len != 2 or suffix[0] != ':') return null;
    return switch (suffix[1]) {
        'v' => .display,
        '?' => .debug,
        'p' => .pretty,
        else => null,
    };
}

fn appendFormatLiteral(out: *std.ArrayList(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '%') try out.append(alloc, '%');
        try out.append(alloc, text[i]);
        i += 1;
    }
}

fn interpolationEnd(raw: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var quote: u8 = 0;
    var escaped = false;
    var i = start + 1;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn parseInterpolatedString(self: *Parser, token: Token) anyerror!*Node {
    var format = try std.ArrayList(u8).initCapacity(self.alloc, token.text.len + 8);
    var args = try std.ArrayList(*Node).initCapacity(self.alloc, 4);
    errdefer {
        format.deinit(self.alloc);
        args.deinit(self.alloc);
    }

    var literal_start: usize = 0;
    // the lexer records every real interpolation `{` with its decoded index
    // and source position; literal braces (`{{`, `\{`) never get an entry
    //
    // nested braces inside a body do, so skip opens already inside a span
    for (token.interp_opens) |open| {
        if (open.idx < literal_start) continue;
        const end = interpolationEnd(token.text, open.idx) orelse {
            try self.recordError(.UnexpectedToken, "unterminated string interpolation", token.span());
            return self.allocExpr(token.span(), .{ .string = token.text });
        };
        try appendFormatLiteral(&format, self.alloc, token.text[literal_start..open.idx]);

        var body = token.text[open.idx + 1 .. end];
        var mode: InterpolationMode = .display;
        const trailing = std.mem.trimEnd(u8, body, " \t\r\n");
        if (trailing.len >= 2) {
            if (interpolationMode(trailing[trailing.len - 2 ..])) |found| {
                mode = found;
                body = body[0 .. trailing.len - 2];
            }
        }
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
            try self.recordError(.UnexpectedToken, "empty string interpolation", token.span());
            return self.allocExpr(token.span(), .{ .string = token.text });
        }

        // lex the body as a fragment anchored at the `{`; tokens come out
        // with real source positions, so node spans need no rebasing
        const embedded_tokens = try lexer.lexAt(self.alloc, body, .{
            .offset = open.offset + 1,
            .line = open.line,
            .column = open.column + 1,
        });
        const value: *Node = switch (try parseTokensReport(self.alloc, embedded_tokens)) {
            .ok => |expr| expr,
            // fold the fragment's diagnostics into this parse instead of
            // aborting the whole file: a bad body (e.g. 1e999) must not
            // discard errors already accumulated elsewhere in the file
            .err => |failure| blk: {
                self.had_errors = true;
                if (self.first_error_kind == null) {
                    self.first_error_kind = failure.kind;
                    if (diagnostic.firstError(failure.report)) |msg| self.first_error_message = msg;
                }
                try self.errors.appendSlice(self.alloc, failure.report.parts);
                break :blk try self.allocExpr(token.span(), .{ .string = token.text });
            },
        };
        try args.append(self.alloc, value);
        try format.appendSlice(self.alloc, switch (mode) {
            .display => "%v",
            .debug => "%?",
            .pretty => "%p",
        });
        literal_start = end + 1;
    }

    try appendFormatLiteral(&format, self.alloc, token.text[literal_start..]);
    if (args.items.len == 0) {
        const text = try format.toOwnedSlice(self.alloc);
        args.deinit(self.alloc);
        return self.allocExpr(token.span(), .{ .string = text });
    }

    var call_args = try std.ArrayList(*Node).initCapacity(self.alloc, args.items.len + 1);
    try call_args.append(
        self.alloc,
        try self.allocExpr(token.span(), .{ .string = try format.toOwnedSlice(self.alloc) }),
    );

    try call_args.appendSlice(self.alloc, args.items);
    args.deinit(self.alloc);
    const callee = try self.allocExpr(token.span(), .{ .ident = "fmt" });
    return self.allocExpr(token.span(), .{ .call = .{
        .callee = callee,
        .args = try call_args.toOwnedSlice(self.alloc),
    } });
}

const LogicalBindingTable = std.EnumArray(TokenType, ?LogicalBinding);
const logical_binding_table: LogicalBindingTable = blk: {
    var table = LogicalBindingTable.initFill(null);
    table.set(.kw_or, .{ .left = 10, .right = 11 });
    table.set(.kw_and, .{ .left = 20, .right = 21 });
    table.set(.kw_orelse, .{ .left = 12, .right = 13 }); // keep it a bit lower than or
    break :blk table;
};

const CompoundAssignTable = std.EnumArray(TokenType, ?ast.BinOp);
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
    .multiline_string,
    .lsquiggly,
});

const call_stmt_boundary_tokens = makeTokenSet(&.{
    .string,
    .multiline_string,
    .lsquiggly,
});

const expr_start_tokens = makeTokenSet(&.{
    .number,       .string,    .multiline_string, .hash,     .ident,
    .kw_const,     .kw_let,    .kw_macro,         .minus,    .kw_not,
    .pipe_forward, .lparen,    .kw_fn,            .kw_if,    .kw_unless,
    .kw_match,     .kw_do,     .kw_loop,          .kw_break, .kw_continue,
    .kw_return,    .kw_import, .kw_spawn,         .kw_join,  .kw_yield,
    .lsquiggly,    .kw_type,   .kw_pub,           .eof,
});

/// expr allows bare call after it (ident, field, call, fn_expr)
fn exprAllowsBareCall(expr: *const Node) bool {
    return switch (expr.expr) {
        .ident, .field, .call, .fn_expr => true,
        else => false,
    };
}

fn exprAllowsParenCall(expr: *const Node) bool {
    return switch (expr.expr) {
        .ident, .field, .call, .fn_expr, .index => true,
        else => false,
    };
}

//
// test smokezone
//

pub const testing = struct {
    pub fn renderExpr(source: []const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const tokens = try lexer.lexAt(arena.allocator(), source, .{});
        defer arena.allocator().free(tokens);
        const expr = try parseTokens(arena.allocator(), tokens);
        var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer buf.deinit();

        try expr.print(&buf.writer);
        return try buf.toOwnedSlice();
    }

    pub fn expectPrinted(source: []const u8, expected: []const u8) !void {
        const rendered = try renderExpr(source);
        defer std.testing.allocator.free(rendered);

        try std.testing.expectEqualStrings(expected, rendered);
    }

    pub fn parseOne(alloc: std.mem.Allocator, source: []const u8) !*Node {
        const tokens = try lexer.lexAt(alloc, source, .{});
        return parseTokens(alloc, tokens);
    }
};

test "parses string interpolation as fmt calls" {
    try testing.expectPrinted("\"hello #{name}\"", "(call fmt \"hello %v\" name)");
    try testing.expectPrinted("\"#{value:?} #{value:p}\"", "(call fmt \"%? %p\" value value)");
    try testing.expectPrinted("\"literal {{brace}}\"", "\"literal {brace}\"");
}

test "interpolation value nodes carry real source spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "print \"hi #{name}\"", .{});
    const root = try parseTokens(alloc, tokens);
    const value = root.expr.call.args[0].expr.call.args[1];
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
    const tokens = try lexer.lexAt(alloc, src, .{});
    const root = try parseTokens(alloc, tokens);
    const call = root.expr.call.args[0].expr.call;
    try std.testing.expectEqual(@as(usize, 3), call.args.len);
    const a = call.args[1];
    const b = call.args[2];
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

    const tokens = try lexer.lexAt(alloc, "print \"a #{ \\\"b #{c}\\\" } d\"", .{});
    const root = try parseTokens(alloc, tokens);
    const outer = root.expr.call.args[0].expr.call;
    const inner = outer.args[1].expr.call;
    const c = inner.args[1];
    try std.testing.expectEqual(@as(u32, 1), c.span.line);
    try std.testing.expectEqual(@as(u32, 18), c.span.column);
    try std.testing.expectEqual(@as(usize, 17), c.span.start);
    try std.testing.expectEqual(@as(usize, 18), c.span.end);
}

test "quasiquote inner nodes carry template spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "let q = `a + b`", .{});
    const root = try parseTokens(alloc, tokens);
    const qq = root.expr.decl.inner.expr.binding.value.expr.quasiquote;
    const inner = qq.inner;
    try std.testing.expectEqual(@as(u32, 1), inner.span.line);
    try std.testing.expectEqual(@as(u32, 10), inner.span.column);
    try std.testing.expectEqual(@as(usize, 9), inner.span.start);
    try std.testing.expectEqual(@as(usize, 14), inner.span.end);
}

test "parses doc comment on function declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ #* adds *#
        \\ fn add(a, b) a + b
    ;
    const tokens = try lexer.lexAt(alloc, src, .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.inner.expr == .binding);
    const b = root.expr.decl.inner.expr.binding;
    try std.testing.expect(b.value.expr == .fn_expr);
    try std.testing.expectEqualStrings("adds", root.expr.decl.doc.?);
}

test "doc comment attaches to non-fn const binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ #* a plain value *#
        \\ const a = 5
    ;
    const tokens = try lexer.lexAt(alloc, src, .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    const b = root.expr.decl.inner.expr.binding;
    try std.testing.expect(b.value.expr == .number);
    try std.testing.expectEqualStrings("a plain value", root.expr.decl.doc.?);
}

test "parses @native annotation on function declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ @native
        \\ fn add(a, b) a + b
    ;
    const tokens = try lexer.lexAt(alloc, src, .{});
    const root = try parseTokens(alloc, tokens);
    const value = root.expr.decl.inner.expr.binding.value;
    try std.testing.expect(value.expr == .fn_expr);
    try std.testing.expect(value.expr.fn_expr.native);
    try std.testing.expect(value.expr.fn_expr.doc == null);
}

test "parses @native with a doc comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ #* adds two numbers *#
        \\ @native fn add(a, b) a + b
    ;
    const tokens = try lexer.lexAt(alloc, src, .{});
    const root = try parseTokens(alloc, tokens);
    const b = root.expr.decl.inner.expr.binding;
    try std.testing.expect(b.value.expr == .fn_expr);
    try std.testing.expect(b.value.expr.fn_expr.native);
    try std.testing.expectEqualStrings("adds two numbers", root.expr.decl.doc.?);
}

test "unknown attribute is a parse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "@bar fn foo() 1", .{});
    try std.testing.expectError(error.UnknownAttribute, parseTokens(alloc, tokens));
}

test "parses import statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "import \"json\"", .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .import_stmt);
    try std.testing.expectEqualStrings("json", root.expr.import_stmt.path);
    try std.testing.expectEqualStrings("json", root.expr.import_stmt.name);
    try std.testing.expect(!root.expr.import_stmt.pub_);
}

test "parses multi-import table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const tokens = try lexer.lexAt(alloc, "import {\"a\", \"b\"}", .{});
        const root = try parseTokens(alloc, tokens);
        try std.testing.expect(root.expr == .block);
        try std.testing.expect(root.expr.block.len == 2);
        try std.testing.expect(root.expr.block[0].expr == .import_stmt);
        try std.testing.expectEqualStrings("a", root.expr.block[0].expr.import_stmt.name);
        try std.testing.expect(root.expr.block[1].expr == .import_stmt);
        try std.testing.expectEqualStrings("b", root.expr.block[1].expr.import_stmt.name);
    }
    {
        const tokens = try lexer.lexAt(alloc, "import {x = \"a\"}", .{});
        const root = try parseTokens(alloc, tokens);
        try std.testing.expect(root.expr == .block);
        try std.testing.expect(root.expr.block.len == 1);
        try std.testing.expect(root.expr.block[0].expr == .import_stmt);
        try std.testing.expectEqualStrings("x", root.expr.block[0].expr.import_stmt.name);
        try std.testing.expectEqualStrings("a", root.expr.block[0].expr.import_stmt.path);
    }
    {
        const tokens = try lexer.lexAt(alloc, "import {x = \"a\", \"b\"}", .{});
        const root = try parseTokens(alloc, tokens);
        try std.testing.expect(root.expr == .block);
        try std.testing.expect(root.expr.block.len == 2);
        try std.testing.expectEqualStrings("x", root.expr.block[0].expr.import_stmt.name);
        try std.testing.expectEqualStrings("b", root.expr.block[1].expr.import_stmt.name);
    }
}

test "parses pub const with pub_ flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "pub const x = 1", .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
    try std.testing.expect(root.expr.decl.kind == .con);
}

test "parses pub macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "pub macro assert! `(expr)` `(expr)`";
    const tokens = try lexer.lexAt(alloc, src, .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
    try std.testing.expect(root.expr.decl.inner.expr == .macro_expr);
    try std.testing.expectEqualStrings("assert!", root.expr.decl.inner.expr.macro_expr.name);
}

test "parses pub import statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "pub import \"json\"", .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .import_stmt);
    try std.testing.expect(root.expr.import_stmt.pub_);
    try std.testing.expectEqualStrings("json", root.expr.import_stmt.path);
}

test "parses pub fn with pub_ flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "pub fn f() 42", .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
}

test "parses pub proc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "pub proc inc!(n) n + 1", .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
    try std.testing.expect(root.expr.decl.inner.expr == .proc_macro);
    try std.testing.expectEqualStrings("inc!", root.expr.decl.inner.expr.proc_macro.name);
}

test "parses pub type with pub_ flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "pub type MyInt = int", .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
    try std.testing.expect(root.expr.decl.kind == .type_alias_decl);
}

test "parses declare as an ambient decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "pub declare ring = fn(volume: number, label: string) -> bool", .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
    try std.testing.expect(root.expr.decl.kind == .declare_decl);
    const alias = root.expr.decl.inner.expr.type_alias;
    try std.testing.expectEqualStrings("ring", alias.name);
    try std.testing.expect(alias.type_expr.kind == .function);
}

test "declare fn doc comment attaches to the decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(
        alloc,
        "#* lights the lamp loudness *# declare lamp = fn(volume: number) -> bool",
        .{},
    );
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expectEqualStrings(
        "lights the lamp loudness",
        root.expr.decl.doc.?,
    );
}

test "doc comment attaches to any decl, docs land on the declared thing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "#* a doc *# const x = 42", .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expectEqualStrings("a doc", root.expr.decl.doc.?);
}

test "declare defaults to pub" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lexAt(alloc, "declare ring = fn() -> int", .{});
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr.decl.pub_);
}

test "parses repeated paren calls" {
    try testing.expectPrinted("f()()", "(call (call f))");
    try testing.expectPrinted("f()()()", "(call (call (call f)))");
    try testing.expectPrinted("f()()()()", "(call (call (call (call f))))");
}

test "dotted heads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const typed = try testing.parseOne(alloc, "pub type uri.Hi[T] = {n: T}");
    try std.testing.expect(typed.expr.decl.kind == .type_alias_decl);
    const alias = typed.expr.decl.inner.expr.type_alias;
    try std.testing.expectEqualStrings("uri", alias.name);
    try std.testing.expectEqualStrings("Hi", ast.bareName(alias));
    try std.testing.expectEqual(@as(usize, 1), alias.declare_tps.len);
    try std.testing.expectEqualStrings("T", alias.declare_tps[0]);
    const segs = alias.declare_head.?.module;
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("uri", segs[0]);
    try std.testing.expectEqualStrings("Hi", segs[1]);

    const macro_root = try testing.parseOne(alloc, "pub macro uri.shout! `(%w:expr)` `%w`");
    try std.testing.expectEqualStrings("uri.shout!", macro_root.expr.decl.inner.expr.macro_expr.name);

    const proc_root = try testing.parseOne(alloc, "pub proc uri.asdf!(m) do m end");
    try std.testing.expectEqualStrings("uri.asdf!", proc_root.expr.decl.inner.expr.proc_macro.name);

    // they reject core slots & deep paths
    for ([_][]const u8{
        "pub type string:foo = num",
        "pub macro a.b.c! `(%w:expr)` `%w`",
        "pub macro string:x! `(%w:expr)` `%w`",
        "pub proc a.b.c!(m) do m end",
    }) |source| {
        try std.testing.expectError(error.UnexpectedToken, testing.parseOne(alloc, source));
    }
}
