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

// left < right = left-assoc (a + b + c = (a + b) + c)
// left > right = right-assoc (a = b = c = a = (b = c))
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
errors: std.ArrayList(diagnostic.Part) = undefined,
errors_inited: bool = false,
first_error_kind: ?Kind = null,
first_error_message: []const u8 = "",
had_errors: bool = false,

fn initErrors(self: *Parser) !void {
    self.errors = try std.ArrayList(diagnostic.Part).initCapacity(self.alloc, 8);
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
    const parts = try self.errors.toOwnedSlice(self.alloc);
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
}

fn syncToNextStatement(self: *Parser, terminator: TokenType) void {
    if (self.check(terminator) or self.check(.eof)) return;
    self.pos = @min(self.pos + 1, self.tokens.len - 1);
    while (!self.check(terminator) and !self.check(.eof)) {
        if (self.peekStartsExpression()) break;
        self.pos += 1;
    }
}

/// starts with a prefix node, then consumes infix/postfix ops while binding power allows
/// min_bp is the floor; if an operator's left power is below this, itll stop and return
fn parseExpression(self: *Parser, min_bp: u8) anyerror!*Node {
    var left = try self.parsePrefix();

    while (true) {
        if (self.stop_token) |stop| if (self.check(stop)) break;
        if (self.stop_on_stmt_start and self.isStatementBoundary(left)) break;

        // postfix `obj.field`
        if (self.match(.dot)) {
            const name = try self.expectIdent();
            left = try self.allocExpr(Span.merge(left.span, name.span()), .{
                .field = .{ .object = left, .name = name.text },
            });
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
                    var type_args = try std.ArrayList([]const u8).initCapacity(self.alloc, 2);
                    defer type_args.deinit(self.alloc);
                    while (!self.check(.rbracket)) {
                        const tp = try self.expectIdent();
                        try type_args.append(self.alloc, tp.text);
                        if (!self.match(.comma)) break;
                    }
                    _ = try self.expect(.rbracket);
                    _ = try self.expect(.lparen);
                    const args = try self.parseDelimitedExprList(.rparen);
                    const close = try self.expect(.rparen);
                    left = try self.allocExpr(Span.merge(left.span, close.span()), .{
                        .call = .{ .callee = left, .args = args, .type_args = try type_args.toOwnedSlice(self.alloc) },
                    });
                    continue;
                }
            }
            _ = try self.expect(.lbracket);
            const key = try self.parseExpression(0);
            const close = try self.expect(.rbracket);
            left = try self.allocExpr(Span.merge(left.span, close.span()), .{
                .index = .{ .object = left, .key = key },
            });
            continue;
        }

        // postfix: paren call `f(args)`; only if f allows it (ident, field, call, fn, index)
        if (self.peek().type == .lparen and (exprAllowsParenCall(left) or self.isTightSuffix(left))) {
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

        // infix: comp assign `x += y`; desugars to `x = x + y`
        const comp_binop = compound_assign_table.get(self.peek().type);
        if (BP.compound >= min_bp and comp_binop != null) {
            const binop = comp_binop.?;
            _ = self.advance();
            const right = try self.parseExpression(BP.compound);
            const binary = try self.allocExpr(Span.merge(left.span, right.span), .{
                .binary = .{ .op = binop, .left = left, .right = right },
            });
            left = try self.allocExpr(binary.span, .{
                .assign_expr = .{ .target = try self.exprToPattern(left), .value = binary },
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

            var step_node: *Node = undefined;
            var end_node: *Node = undefined;

            if (self.match(.dotdot)) {
                step_node = step_or_end;
                end_node = try self.parseExpression(BP.range);
            } else {
                step_node = try self.allocExpr(step_or_end.span, .{ .number = .{ .value = 1, .is_float = false } });
                end_node = step_or_end;
            }
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
                        try self.parseExpression(bp + 1);
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
            if (value > @import("revo").memory.PAYLOAD_MASK)
                try self.recordError(.InvalidNumber, "number over 2^48 (281474976710655)", token.span());
            break :blk self.allocExpr(token.span(), .{ .number = .{ .value = value, .is_float = is_float } });
        },
        .string => self.allocExpr(token.span(), .{ .string = token.text }),
        .multiline_string => self.allocExpr(token.span(), .{ .multiline_string = token.text }),
        .hash => self.allocExpr(token.span(), .{ .hash = token.text[1..] }),
        .ident => if (std.mem.eql(u8, token.text, "@doc"))
            self.parseDocAttr(token)
        else
            self.allocExpr(token.span(), .{ .ident = token.text }),
        .kw_const, .kw_global, .kw_let, .kw_struct, .kw_test, .kw_suite => self.parseDecl(token),
        .kw_proc => self.parseProc(token),
        .kw_fn => self.parseFn(token),
        .minus => self.parseUnary(.negate, 60, token),
        .kw_not => self.parseUnary(.not, 35, token),
        .lparen => self.parseParenExpr(token),
        .kw_if => self.parseIf(token),
        .kw_match => self.parseMatch(token, null),
        .kw_do => self.parseBlock(token),
        .kw_loop => self.parseLoop(token),
        .kw_for => self.parseFor(token),
        .kw_while => self.parseWhile(token),
        .kw_break => self.parseExitExpr(.break_expr, token),
        .kw_return => self.parseExitExpr(.return_expr, token),
        .kw_comp => self.parseComp(token),
        .kw_import => self.parseImport(token),
        .kw_spawn => self.parseSpawn(token),
        .kw_join => self.parseJoin(token),
        .kw_yield => self.parseYield(token),
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
            try self.recordError(.UnexpectedToken, "':' without a following name is not a value; use ':name' for an atom", token.span());
            break :blk self.allocExpr(token.span(), .nil);
        },
        else => return error.UnexpectedToken,
    };
}

/// -, not
fn parseUnary(self: *Parser, op: ast.UnOp, right_bp: u8, token: Token) anyerror!*Node {
    const expr = try self.parseExpression(right_bp);
    return self.allocExpr(Span.merge(token.span(), expr.span), .{ .unary = .{ .op = op, .expr = expr } });
}

fn parseDocAttr(self: *Parser, token: Token) anyerror!*Node {
    const doc_token = self.advance();
    const doc_text = switch (doc_token.type) {
        .string, .multiline_string, .backtick_string => doc_token.text,
        else => return error.UnexpectedToken,
    };

    const target = try self.parsePrefix();
    return self.applyDocAttr(target, doc_text, token.span());
}

fn applyDocAttr(self: *Parser, node: *Node, doc_text: []const u8, doc_span: Span) anyerror!*Node {
    switch (node.expr) {
        .decl => {
            _ = try self.applyDocAttr(node.expr.decl.inner, doc_text, doc_span);
            return node;
        },
        .fn_expr => {
            node.expr.fn_expr.doc = doc_text;
            return node;
        },
        .binding => |binding| {
            const value = binding.value;
            if (value.expr != .fn_expr) return error.UnexpectedToken;
            value.expr.fn_expr.doc = doc_text;
            return node;
        },
        .assign_expr => {
            const value = node.expr.assign_expr.value;
            if (value.expr != .fn_expr) return error.UnexpectedToken;
            value.expr.fn_expr.doc = doc_text;
            return node;
        },
        else => {
            return error.UnexpectedToken;
        },
    }
}

/// fn(params) body               - anonymous function
/// fn name(params) body          - const name = fn(params) body
/// fn obj:name(params) body      - const obj.name = fn(self, params) body
fn parseFn(self: *Parser, start: Token) anyerror!*Node {
    return self.parseFnWithBodyMin(start, 0);
}

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
            new_params[0] = .{ .name = "self" };
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

        // `fn name[T, U, ...](params) body`
        // `fn name(params) body`
        // parse optional [T, U] type parameters
        const type_params = if (self.match(.lbracket)) blk: {
            var tps = try std.ArrayList([]const u8).initCapacity(self.alloc, 2);
            errdefer tps.deinit(self.alloc);
            while (!self.check(.rbracket)) {
                const tp = try self.expectIdent();
                try tps.append(self.alloc, tp.text);
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.rbracket);
            break :blk try tps.toOwnedSlice(self.alloc);
        } else &.{};

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
            return self.allocExpr(Span.merge(start.span(), body.span), .{ .decl = .{ .inner = bind_node, .kind = ast.DeclKind.con } });
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

/// match expr | pat expr | pat expr
fn parseMatch(self: *Parser, start: Token, subj: ?*Node) anyerror!*Node {
    const subject = subj orelse try self.parseExpression(25);
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
            try matchers.append(self.alloc, .{
                .expr = try self.exprToPattern(try self.parseScoped(null, false, 25)),
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
fn parseTypeAlias(self: *Parser, start: Token) anyerror!*Node {
    const name = try self.expectIdent();
    _ = try self.expect(.assign);
    const type_expr = try self.parseTypeExpr();
    return self.allocExpr(Span.merge(start.span(), type_expr.span), .{
        .type_alias = .{ .name = name.text, .type_expr = type_expr },
    });
}

fn parseTypeExpr(self: *Parser) anyerror!*ast.TypeExpr {
    const left = try self.parseTypeExprAtom();
    if (self.match(.pipe)) {
        var variants = try std.ArrayList(*ast.TypeExpr).initCapacity(self.alloc, 4);
        errdefer variants.deinit(self.alloc);
        try collectTypeVariants(self.alloc, &variants, left);
        try collectTypeVariants(self.alloc, &variants, try self.parseTypeExprAtom());
        while (self.match(.pipe))
            try collectTypeVariants(self.alloc, &variants, try self.parseTypeExprAtom());
        const span = ast.Span.merge(variants.items[0].span, variants.items[variants.items.len - 1].span);
        return try ast.allocTypeExpr(self.alloc, span, .{ .union_of = try variants.toOwnedSlice(self.alloc) });
    }
    return left;
}

fn collectTypeVariants(alloc: std.mem.Allocator, variants: *std.ArrayList(*ast.TypeExpr), te: *ast.TypeExpr) !void {
    if (te.kind == .union_of) {
        try variants.appendSlice(alloc, te.kind.union_of);
    } else {
        try variants.append(alloc, te);
    }
}

fn parseParenTypeExpr(self: *Parser, start: Token) anyerror!*ast.TypeExpr {
    const inner = try self.parseTypeExpr();
    if (self.match(.comma)) {
        var items = try std.ArrayList(*ast.TypeExpr).initCapacity(self.alloc, 4);
        errdefer items.deinit(self.alloc);
        try items.append(self.alloc, inner);
        while (!self.check(.rparen)) {
            try items.append(self.alloc, try self.parseTypeExpr());
            if (!self.match(.comma)) break;
        }
        const close = try self.expect(.rparen);
        return try ast.allocTypeExpr(self.alloc, ast.Span.merge(start.span(), close.span()), .{
            .tuple = try items.toOwnedSlice(self.alloc),
        });
    }
    _ = try self.expect(.rparen);
    return inner;
}

fn parseTypeExprAtom(self: *Parser) anyerror!*ast.TypeExpr {
    return switch (self.peek().type) {
        .ident => blk: {
            const tok = self.advance();
            break :blk try ast.allocTypeExpr(self.alloc, tok.span(), .{ .named = tok.text });
        },
        .hash => blk: {
            const tok = self.advance();
            break :blk try ast.allocTypeExpr(self.alloc, tok.span(), .{ .atom = tok.text });
        },
        .kw_fn => blk: {
            const start = self.advance();
            _ = try self.expect(.lparen);
            const params = try self.parseParamList(.rparen);
            _ = try self.expect(.rparen);
            const return_type = if (self.match(.arrow)) try self.parseTypeExpr() else null;
            const end = if (return_type) |r| r.span else self.tokens[self.pos - 1].span();
            break :blk try ast.allocTypeExpr(self.alloc, ast.Span.merge(start.span(), end), .{
                .function = .{ .params = params, .return_type = return_type },
            });
        },
        .lparen => blk: {
            const start = self.advance();
            break :blk try self.parseParenTypeExpr(start);
        },
        else => return error.UnexpectedToken,
    };
}

/// const x = expr or let x = expr, with const (a, b) = <expr> tuple destructuring
/// with tuples and type annotations
fn parseBinding(self: *Parser, comptime kind: ast.DeclKind, start: Token) anyerror!*Node {
    comptime var mutable: bool = false;
    comptime {
        if (kind == ast.DeclKind.con) {
            mutable = false;
        } else if (kind == ast.DeclKind.let) {
            mutable = true;
        } else if (kind == ast.DeclKind.global) {
            mutable = false;
        } else {
            @compileError("unsupported binding kind to parseBinding");
        }
    }

    var binding: ast.Binding = .{ .target = undefined, .value = undefined, .mutable = mutable };

    if (self.check(.lparen)) {
        _ = self.advance();
        binding.target = try self.parseTuplePattern(.rparen);
        _ = try self.expect(.rparen);
    } else {
        const first = try self.expectIdent();
        if (self.match(.comma)) {
            var items = try std.ArrayList(*Node).initCapacity(self.alloc, 2);
            errdefer items.deinit(self.alloc);
            try items.append(self.alloc, try self.allocExpr(first.span(), .{ .ident = first.text }));

            while (true) {
                const item = try self.expectIdent();
                try items.append(self.alloc, try self.allocExpr(item.span(), .{ .ident = item.text }));
                if (!self.match(.comma)) break;
            }
            binding.target = try self.allocExpr(ast.spanFromNodes(items.items, first.span()), .{
                .tuple_pattern = try items.toOwnedSlice(self.alloc),
            });
        } else {
            binding.target = try self.allocExpr(first.span(), .{ .ident = first.text });
        }
    }

    if (self.match(.colon)) {
        binding.type_name = try self.parseTypeExpr();
    }
    _ = try self.expect(.assign);
    binding.value = try self.parseStatementExpression(0);

    // for const x = import "foo", use binding name as module name
    // so macros qualify as x.macro! instead of foo.macro!
    if (binding.value.expr == .import_stmt and binding.target.expr == .ident) {
        binding.value.expr.import_stmt.name = binding.target.expr.ident;
    }

    const span = Span.merge(start.span(), binding.value.span);
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
            return try self.parseFn(start);
        },
        .kw_struct => {
            const struct_def = try self.parseStruct(start);
            return self.allocExpr(start.span(), .{ .decl = .{ .inner = struct_def, .kind = ast.DeclKind.struct_decl } });
        },
        .kw_test => {
            const test_block = try self.parseTest(start);
            return self.allocExpr(start.span(), .{ .decl = .{ .inner = test_block, .kind = ast.DeclKind.test_decl } });
        },
        .kw_suite => {
            const suite = try self.parseSuite(start);
            return self.allocExpr(start.span(), .{ .decl = .{ .inner = suite, .kind = ast.DeclKind.suite_decl } });
        },
        .kw_type => {
            if (!self.check(.ident)) return error.UnexpectedToken;
            const type_alias = try self.parseTypeAlias(start);
            return self.allocExpr(start.span(), .{ .decl = .{ .inner = type_alias, .kind = ast.DeclKind.type_alias_decl } });
        },
        else => return error.UnexpectedToken,
    };
}

/// loop do expr end
fn parseLoop(self: *Parser, start: Token) anyerror!*Node {
    const body = try self.parseExpression(0);
    return self.allocExpr(
        Span.merge(start.span(), body.span),
        .{ .loop_expr = .{ .body = body } },
    );
}

/// while <cond> <expr>
fn parseWhile(self: *Parser, start: Token) anyerror!*Node {
    const predicate = try self.parseExpression(25);
    const body = try self.parseExpression(0);
    return self.allocExpr(Span.merge(start.span(), body.span), .{
        .while_loop = .{ .predicate = predicate, .body = body },
    });
}

fn parseFor(self: *Parser, start: Token) anyerror!*Node {
    var params = try std.ArrayList(ast.FnParam).initCapacity(self.alloc, 2);
    errdefer params.deinit(self.alloc);
    const first = try self.expectIdent();
    try params.append(self.alloc, .{ .name = first.text });
    while (self.match(.comma)) {
        const name = try self.expectIdent();
        try params.append(self.alloc, .{ .name = name.text });
    }
    _ = try self.expect(.kw_in);
    const iter = try self.parseExpression(0);
    const body = try self.parseExpression(0);
    return self.allocExpr(Span.merge(start.span(), body.span), .{
        .for_loop = .{ .params = try params.toOwnedSlice(self.alloc), .iter = iter, .body = body },
    });
}

/// return expr or break expr
fn parseExitExpr(self: *Parser, comptime tag: std.meta.Tag(Expr), start: Token) anyerror!*Node {
    const value = try self.parseOptionalTrailingExpr();
    const span =
        if (value) |expr| Span.merge(start.span(), expr.span) else start.span();

    return self.allocExpr(span, @unionInit(Expr, @tagName(tag), value));
}

/// pub prefix on declarations
fn parsePubPrefix(self: *Parser, _: Token) anyerror!*Node {
    const pub_keywords = comptime [_]TokenType{ .kw_const, .kw_let, .kw_fn, .kw_struct, .kw_test, .kw_suite, .kw_proc, .kw_type, .kw_macro, .kw_import };
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
        const name = try self.alloc.dupe(u8, std.fs.path.stem(path_token.text));
        return self.allocExpr(
            Span.merge(start.span(), path_token.span()),
            .{ .import_stmt = .{ .name = name, .path = path_token.text } },
        );
    }
}
/// spawn expr
fn parseSpawn(self: *Parser, start: Token) anyerror!*Node {
    const value = try self.parseExpression(60);
    return self.allocExpr(
        Span.merge(start.span(), value.span),
        .{ .unary = .{ .op = .spawn, .expr = value } },
    );
}

/// join expr
fn parseJoin(self: *Parser, start: Token) anyerror!*Node {
    const value = try self.parseExpression(60);
    return self.allocExpr(
        Span.merge(start.span(), value.span),
        .{ .unary = .{ .op = .join, .expr = value } },
    );
}

/// yield (no expression)
fn parseYield(self: *Parser, start: Token) anyerror!*Node {
    return self.allocExpr(
        start.span(),
        .{ .unary = .{ .op = .yield, .expr = try self.allocExpr(start.span(), .nil) } },
    );
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
    var splices = std.ArrayList([]const u8).initCapacity(self.alloc, splice_count) catch unreachable;

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

    const inner = try lang.parseSource(self.alloc, modified.items);
    return self.allocExpr(token.span(), .{ .quasiquote = .{
        .inner = inner,
        .splices = try splices.toOwnedSlice(self.alloc),
    } });
}

/// macro name! `pattern` `template`
fn parseMacro(self: *Parser, start: Token) anyerror!*Node {
    const name = try self.expect(.ident);
    if (!std.mem.endsWith(u8, name.text, "!")) return error.InvalidMacroName;
    const pattern = try self.expect(.backtick_string);
    const template = try self.expect(.backtick_string);
    return self.allocExpr(Span.merge(start.span(), template.span()), .{ .macro_expr = .{
        .name = name.text,
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
    if (!std.mem.endsWith(u8, first_ident.text, "!")) return error.InvalidProcName;

    if (self.check(.lparen)) {
        _ = try self.expect(.lparen);

        const name = try self.expectIdent();
        const param: ast.FnParam = .{ .name = name.text };
        _ = try self.expect(.rparen);
        const body = try self.parseExpression(0);

        return try self.allocExpr(Span.merge(start.span(), body.span), .{
            .proc_macro = .{ .param = param, .body = body, .name = first_ident.text },
        });
    }
    // neither colon, dot, nor lparen
    return error.UnexpectedToken;
}

/// test "name" do expr end
/// test.skip "name" do expr end
fn parseTest(self: *Parser, start: Token) anyerror!*Node {
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
    return self.allocExpr(Span.merge(start.span(), body.span), .{
        .test_block = .{ .name = name.text, .body = body_fn, .skip = skip },
    });
}

/// suite "name" do ... end
fn parseSuite(self: *Parser, start: Token) anyerror!*Node {
    const name = try self.expect(.string);
    const body_start = try self.expect(.kw_do);
    const body = try self.parseBlock(body_start);

    // wrap suite body in a closure
    const suite_fn = try self.allocExpr(Span.merge(body_start.span(), body.span), .{
        .fn_expr = .{ .params = &.{}, .body = body },
    });
    return self.allocExpr(Span.merge(start.span(), body.span), .{
        .test_suite = .{ .name = name.text, .body = suite_fn },
    });
}

fn parseStruct(self: *Parser, start: Token) anyerror!*Node {
    const name = try self.expectIdent();
    _ = try self.expect(.lsquiggly);

    var items = try std.ArrayList(ast.StructItem).initCapacity(self.alloc, 4);
    errdefer {
        for (items.items) |item| {
            switch (item) {
                .binding => {},
                .field => {},
            }
        }
        items.deinit(self.alloc);
    }
    var end_span = name.span();

    while (!self.check(.rsquiggly) and !self.check(.eof)) {
        // branch const/let
        if (self.check(.kw_const) or self.check(.kw_let)) {
            const binding_start = self.advance();
            const binding_expr = switch (binding_start.type) {
                .kw_const => try self.parseBinding(.con, binding_start),
                .kw_let => try self.parseBinding(.let, binding_start),
                else => return error.UnexpectedToken,
            };
            end_span = binding_expr.span;
            switch (binding_expr.expr) {
                .decl => |decl| switch (decl.inner.expr) {
                    .binding => |binding| try items.append(self.alloc, .{ .binding = binding }),
                    else => return error.UnexpectedToken,
                },
                else => return error.UnexpectedToken,
            }
            if (!self.match(.comma)) break;
            continue;
        }

        // branch fn shorthand: fn name(params) body
        if (self.check(.kw_fn)) {
            const fn_start = self.advance();
            const fn_name = try self.expectIdent();
            const fn_expr = try self.parseFn(fn_start);
            end_span = fn_expr.span;
            const target = try self.allocExpr(fn_name.span(), .{ .ident = fn_name.text });
            const binding: ast.Binding = .{
                .target = target,
                .value = fn_expr,
            };
            try items.append(self.alloc, .{ .binding = binding });
            if (!self.match(.comma)) break;
            continue;
        }

        // branch field: name: type = default
        const field_name = try self.expectIdent();
        var field: ast.StructField = .{ .name = field_name.text, .name_span = field_name.span() };
        if (self.match(.colon)) field.type_name = try self.parseTypeExpr();
        if (self.match(.assign)) field.default_value = try self.parseStatementExpression(0);
        end_span = if (field.default_value) |value| value.span else field_name.span();
        try items.append(self.alloc, .{ .field = field });
        if (!self.match(.comma)) break;
    }

    const close = try self.expect(.rsquiggly);
    return self.allocExpr(Span.merge(start.span(), if (items.items.len == 0) close.span() else end_span), .{
        .struct_def = .{
            .name = name.text,
            .items = try items.toOwnedSlice(self.alloc),
        },
    });
}

/// do expr end
fn parseBlock(self: *Parser, start: Token) anyerror!*Node {
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
    try testing_helpers.top_number("{ a = 5 }[:a]", 5);
    try testing_helpers.top_number("{ 7 = 10 }[7]", 10);
    try testing_helpers.top_number("{ \"a\" = 5 }[\"a\"]", 5);
    try testing_helpers.top_number("let t = { 1 } t[1] = 5 len(t)", 2);
}

test "compiled table square bracket special case" {
    try testing_helpers.top_number("let k = \"asdf\" { [k] = 5 }[\"asdf\"]", 5);
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

/// (expr, expr, ...) or ()
fn parseParenExpr(self: *Parser, start: Token) anyerror!*Node {
    if (self.match(.rparen)) return self.allocExpr(Span.merge(start.span(), self.tokens[self.pos - 1].span()), .nil);

    const first = try self.parseExpression(0);
    if (!self.match(.comma)) {
        _ = try self.expect(.rparen);
        return first;
    }

    var items = try std.ArrayList(*Node).initCapacity(self.alloc, 2);
    errdefer items.deinit(self.alloc);
    try items.append(self.alloc, first);

    while (!self.check(.rparen)) {
        try items.append(self.alloc, try self.parseExpression(0));
        if (!self.match(.comma)) break;
    }

    const close = try self.expect(.rparen);
    return self.allocExpr(Span.merge(start.span(), close.span()), .{ .tuple = try items.toOwnedSlice(self.alloc) });
}

/// (a, b, c) in pattern position, does nested parens n wildcards
fn parseTuplePattern(self: *Parser, terminator: TokenType) anyerror!*Node {
    var items = try std.ArrayList(*Node).initCapacity(self.alloc, 2);
    errdefer items.deinit(self.alloc);

    while (!self.check(terminator)) {
        if (self.checkIdentText("_")) {
            const token = self.advance();
            // wildcard is represented as ident and is the pattern matcher's job
            try items.append(self.alloc, try self.allocExpr(token.span(), .{ .ident = "_" }));
        } else if (self.check(.lparen)) {
            _ = self.advance();
            const nested = try self.parseTuplePattern(.rparen);
            _ = try self.expect(.rparen);
            try items.append(self.alloc, nested);
        } else {
            try items.append(self.alloc, try self.parseExpression(0));
        }

        if (!self.match(.comma)) break;
    }

    const end_span = if (items.items.len == 0) self.peek().span() else items.items[items.items.len - 1].span;
    return self.allocExpr(ast.spanFromNodes(items.items, end_span), .{ .tuple_pattern = try items.toOwnedSlice(self.alloc) });
}

/// turn expression into pattern: expr -> (expr, expr, ...)
fn exprToPattern(self: *Parser, expr: *Node) anyerror!*Node {
    return switch (expr.expr) {
        .tuple => |items| blk: {
            var out = try std.ArrayList(*Node).initCapacity(self.alloc, items.len);
            errdefer out.deinit(self.alloc);
            for (items) |item| try out.append(self.alloc, try self.exprToPattern(item));
            break :blk try self.allocExpr(expr.span, .{ .tuple_pattern = try out.toOwnedSlice(self.alloc) });
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
        var param: ast.FnParam = .{ .name = name.text, .optional = optional };
        if (self.match(.colon)) param.type_name = try self.parseTypeExpr();
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

/// optional trailing expr for return/break (expr or null)
fn parseOptionalTrailingExpr(self: *Parser) anyerror!?*Node {
    if (self.check(.kw_end) or self.check(.pipe) or self.check(.eof)) return null;
    return self.parseExpression(0);
}

/// 0.. and 0..10 :== (:range, 0, 1, limit(int)) and (:range, 0, 1, 10)
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

// token starts expression check for error messages
fn peekStartsExpression(self: *Parser) bool {
    return expr_start_tokens.get(self.peek().type);
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

/// consume identifier or error
fn expectIdent(self: *Parser) error{ExpectedIdentifier}!Token {
    const token = self.peek();
    if (token.type != .ident) return error.ExpectedIdentifier;
    self.pos += 1;
    return token;
}

/// consume and return current token, advance pos
fn advance(self: *Parser) Token {
    const token = self.peek();
    self.pos += 1;
    return token;
}

/// peek current token without consuming
fn peek(self: *Parser) Token {
    return self.tokens[@min(self.pos, self.tokens.len - 1)];
}

/// peek token at offset without consuming
fn peekAt(self: *Parser, offset: usize) Token {
    return self.tokens[@min(self.pos + offset, self.tokens.len - 1)];
}

/// peek identifier and check text match
fn checkIdentText(self: *Parser, text: []const u8) bool {
    const token = self.peek();
    return token.type == .ident and std.mem.eql(u8, token.text, text);
}

fn isStatementBoundary(self: *Parser, left: *const Node) bool {
    if (self.looksLikeTupleAssignStart()) return true;
    if (self.forcesStatementBoundary(left, self.peek().type)) return true;
    if (!self.peekStartsExpression()) return false;
    return !self.canContinueExpression(left);
}

fn forcesStatementBoundary(self: *Parser, left: *const Node, next: TokenType) bool {
    return switch (left.expr) {
        .number => next == .lparen and !self.isTightSuffix(left),
        .decl => expr_start_tokens.get(next),
        .assign_expr, .return_expr, .break_expr => expr_start_tokens.get(next),
        .call => call_stmt_boundary_tokens.get(next),
        else => false,
    };
}

fn canContinueExpression(self: *Parser, left: *const Node) bool {
    const t = self.peek().type;
    if (t == .dot or t == .lbracket or t == .assign or t == .dotdot or t == .pipe_forward or t == .hash) return true;
    if (t == .plus_assign or t == .minus_assign or t == .star_assign or t == .slash_assign or t == .percent_assign) return true;
    if (logical_binding_table.get(t) != null) return true;
    if (infix_binding_table.get(t) != null) return true;
    if (t == .lparen and (exprAllowsParenCall(left) or self.isTightSuffix(left))) return true;
    if (t == .hash and self.peekAt(1).type == .lparen) return true;
    if (self.allow_bare_calls and exprAllowsBareCall(left)) return bare_call_arg_start_tokens.get(t);
    return false;
}

fn looksLikeTupleAssignStart(self: *Parser) bool {
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

fn isTightSuffix(self: *Parser, left: *const Node) bool {
    return left.span.end == self.peek().start;
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
    table.set(.percent, .{ .left = 50, .right = 51, .op = .mod });
    break :blk table;
};

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
    .lparen,
    .string,
    .multiline_string,
    .lsquiggly,
});

const expr_start_tokens = makeTokenSet(&.{
    .number,    .string,       .multiline_string, .hash,      .ident,
    .kw_const,  .kw_let,       .kw_macro,         .kw_struct, .minus,
    .kw_not,    .pipe_forward, .lparen,           .kw_fn,     .kw_if,
    .kw_match,  .kw_do,        .kw_loop,          .kw_break,  .kw_return,
    .kw_import, .kw_spawn,     .kw_join,          .kw_yield,  .lsquiggly,
    .kw_type,   .kw_pub,       .eof,
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

        const tokens = try lexer.lex(arena.allocator(), source);
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
};

test "parses @doc annotation on function declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\ @doc "adds"
        \\ fn add(a, b) a + b
    ;
    const tokens = try lexer.lex(alloc, src);
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.inner.expr == .binding);
    const value = root.expr.decl.inner.expr.binding.value;
    try std.testing.expect(value.expr == .fn_expr);
    try std.testing.expectEqualStrings("adds", value.expr.fn_expr.doc.?);
}

test "parses import statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lex(alloc, "import \"json\"");
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
        const tokens = try lexer.lex(alloc, "import {\"a\", \"b\"}");
        const root = try parseTokens(alloc, tokens);
        try std.testing.expect(root.expr == .block);
        try std.testing.expect(root.expr.block.len == 2);
        try std.testing.expect(root.expr.block[0].expr == .import_stmt);
        try std.testing.expectEqualStrings("a", root.expr.block[0].expr.import_stmt.name);
        try std.testing.expect(root.expr.block[1].expr == .import_stmt);
        try std.testing.expectEqualStrings("b", root.expr.block[1].expr.import_stmt.name);
    }
    {
        const tokens = try lexer.lex(alloc, "import {x = \"a\"}");
        const root = try parseTokens(alloc, tokens);
        try std.testing.expect(root.expr == .block);
        try std.testing.expect(root.expr.block.len == 1);
        try std.testing.expect(root.expr.block[0].expr == .import_stmt);
        try std.testing.expectEqualStrings("x", root.expr.block[0].expr.import_stmt.name);
        try std.testing.expectEqualStrings("a", root.expr.block[0].expr.import_stmt.path);
    }
    {
        const tokens = try lexer.lex(alloc, "import {x = \"a\", \"b\"}");
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

    const tokens = try lexer.lex(alloc, "pub const x = 1");
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
    const tokens = try lexer.lex(alloc, src);
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

    const tokens = try lexer.lex(alloc, "pub import \"json\"");
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .import_stmt);
    try std.testing.expect(root.expr.import_stmt.pub_);
    try std.testing.expectEqualStrings("json", root.expr.import_stmt.path);
}

test "parses pub fn with pub_ flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lex(alloc, "pub fn f() 42");
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
}

test "parses pub proc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lex(alloc, "pub proc inc!(n) n + 1");
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
    try std.testing.expect(root.expr.decl.inner.expr == .proc_macro);
    try std.testing.expectEqualStrings("inc!", root.expr.decl.inner.expr.proc_macro.name);
}

test "parses pub struct with pub_ flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lex(alloc, "pub struct User { name: string }");
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
    try std.testing.expect(root.expr.decl.kind == .struct_decl);
}

test "parses pub type with pub_ flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lexer.lex(alloc, "pub type MyInt = int");
    const root = try parseTokens(alloc, tokens);
    try std.testing.expect(root.expr == .decl);
    try std.testing.expect(root.expr.decl.pub_);
    try std.testing.expect(root.expr.decl.kind == .type_alias_decl);
}
