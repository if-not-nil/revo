const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("Lexer.zig");
const types = @import("compiler/types.zig");
const TypeInfo = types.TypeInfo;
const UnionVariant = types.UnionVariant;
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;

/// parse a type string from stdlib annotations and compiler fn signatures
/// handles T... (variadic marker, stripped) and delegates to parse() + evalTypeExpr()
/// ex: "number?" -> int | :nil,  "string..." -> string,  "int | :nil" -> int | :nil
///     ctx must support .alloc and .resolveTypeAlias(name) -> ?TypeInfo
pub fn parseTypeString(ctx: anytype, s: []const u8) !TypeInfo {
    const trimmed = if (std.mem.endsWith(u8, s, "...")) s[0 .. s.len - 3] else s;
    if (trimmed.len == 0) return .any;
    const tokens = try Lexer.lex(ctx.alloc, trimmed);
    var pos: usize = 0;
    const te = try parse(tokens, &pos, ctx.alloc);
    return try evalTypeExpr(ctx, te);
}

/// advances pos past the consumed tokens
pub fn parse(tokens: []const Token, pos: *usize, alloc: std.mem.Allocator) !*ast.TypeExpr {
    var p = Parser{ .tokens = tokens, .pos = pos, .alloc = alloc };
    return try p.parseExpr();
}

const Parser = struct {
    tokens: []const Token,
    pos: *usize,
    alloc: std.mem.Allocator,
    fn peek(self: *Parser) Token {
        return self.tokens[self.pos.*];
    }
    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos.*];
        self.pos.* += 1;
        return t;
    }
    fn check(self: *Parser, t: TokenType) bool {
        return self.peek().type == t;
    }
    fn match(self: *Parser, t: TokenType) bool {
        if (self.check(t)) {
            _ = self.advance();
            return true;
        }
        return false;
    }
    fn expect(self: *Parser, t: TokenType) !Token {
        if (self.check(t)) return self.advance();
        return error.UnexpectedToken;
    }

    fn span(self: *Parser, start: Token) ast.Span {
        return ast.Span.merge(start.span(), self.tokens[self.pos.* - 1].span());
    }

    /// type union expression (lowest-precedence operator)
    /// * "int | string"  "number? | :nil"  "int"
    fn parseExpr(self: *Parser) anyerror!*ast.TypeExpr {
        const left = try self.parseAtom();
        if (self.match(.pipe)) {
            var variants = try std.ArrayList(*ast.TypeExpr).initCapacity(self.alloc, 4);
            errdefer variants.deinit(self.alloc);
            try collectVariants(self.alloc, &variants, left);
            try collectVariants(self.alloc, &variants, try self.parseAtom());
            while (self.match(.pipe))
                try collectVariants(self.alloc, &variants, try self.parseAtom());
            return try ast.allocTypeExpr(self.alloc, left.span, .{ .union_of = try variants.toOwnedSlice(self.alloc) });
        }
        return left;
    }

    /// atomic type expression with no union operators
    /// * ident (name):      "number", "string", "MyStruct"
    /// * ident? (optional): "number?" -> union_of(named("number"), atom(":nil"))
    /// * ident<T>:          "table<int>", "table<string, int>"
    /// * :atom (hash):      ":nil", ":ok", ":err"
    /// * fn(T) -> U:        "fn(int) -> bool"
    /// * (T):               "(int | string)" (paren grouping), "(int, string)" (tuple)
    /// * !T / ?T:           "!int", "?int" (error union - prefix bang or kw_not)
    fn parseAtom(self: *Parser) !*ast.TypeExpr {
        const tok = self.peek();
        switch (tok.type) {
            .ident => {
                const start = self.advance();
                const text = start.text;
                // "number?" -> optional; lexer treats ? as ident-char, so it splits here
                if (std.mem.endsWith(u8, text, "?")) {
                    const name = try ast.allocTypeExpr(self.alloc, start.span(), .{ .named = text[0 .. text.len - 1] });
                    const nil_atom = try ast.allocTypeExpr(self.alloc, start.span(), .{ .atom = ":nil" });
                    return try ast.allocTypeExpr(self.alloc, start.span(), .{ .union_of = &.{ name, nil_atom } });
                }
                if (self.match(.lt)) {
                    var params = try std.ArrayList(*ast.TypeExpr).initCapacity(self.alloc, 4);
                    errdefer params.deinit(self.alloc);
                    try params.append(self.alloc, try self.parseExpr());
                    while (self.match(.comma))
                        try params.append(self.alloc, try self.parseExpr());
                    _ = try self.expect(.gt);
                    return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                        .parameterized = .{ .name = tok.text, .params = try params.toOwnedSlice(self.alloc) },
                    });
                }
                return try ast.allocTypeExpr(self.alloc, tok.span(), .{ .named = tok.text });
            },
            .hash => {
                return try ast.allocTypeExpr(self.alloc, self.advance().span(), .{ .atom = tok.text });
            },
            .kw_fn => {
                const start = self.advance();
                _ = try self.expect(.lparen);
                const params = try self.parseFnParams();
                _ = try self.expect(.rparen);
                const return_type = if (self.match(.arrow)) try self.parseExpr() else null;
                return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                    .function = .{ .params = params, .return_type = return_type },
                });
            },
            .lparen => {
                const start = self.advance();
                const inner = try self.parseExpr();
                if (self.match(.comma)) {
                    var items = try std.ArrayList(*ast.TypeExpr).initCapacity(self.alloc, 4);
                    errdefer items.deinit(self.alloc);
                    try items.append(self.alloc, inner);
                    while (!self.check(.rparen)) {
                        try items.append(self.alloc, try self.parseExpr());
                        if (!self.match(.comma)) break;
                    }
                    _ = try self.expect(.rparen);
                    return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                        .tuple = try items.toOwnedSlice(self.alloc),
                    });
                }
                _ = try self.expect(.rparen);
                return inner;
            },
            .kw_not, .bang => {
                const start = self.advance();
                const inner = try self.parseExpr();
                return try ast.allocTypeExpr(self.alloc, self.span(start), .{ .error_union = inner });
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseFnParams(self: *Parser) ![]const ast.FnParam {
        var params = try std.ArrayList(ast.FnParam).initCapacity(self.alloc, 4);
        errdefer params.deinit(self.alloc);
        while (!self.check(.rparen) and !self.check(.eof)) {
            const name = try self.expect(.ident);
            const type_name = if (self.match(.colon)) try self.parseExpr() else null;
            try params.append(self.alloc, .{ .name = name.text, .type_name = type_name });
            if (!self.match(.comma)) break;
        }
        return try params.toOwnedSlice(self.alloc);
    }
};

fn collectVariants(alloc: std.mem.Allocator, variants: *std.ArrayList(*ast.TypeExpr), te: *ast.TypeExpr) !void {
    if (te.kind == .union_of) {
        try variants.appendSlice(alloc, te.kind.union_of);
    } else {
        try variants.append(alloc, te);
    }
}

/// type ast back into a TypeInfo
/// every TypeExpr kind must be handled here; this is the single place where AST type
/// nodes becomes semantic TypeInfo values
/// ctx must support .alloc, .isTypeParam(name) -> bool, and .resolveTypeAlias(name) -> ?TypeInfo
pub fn evalTypeExpr(ctx: anytype, te: *const ast.TypeExpr) !TypeInfo {
    switch (te.kind) {
        // "number" -> int (from type_name_map), "MyStruct" -> struct_type
        .named => |name| {
            if (ctx.isTypeParam(name)) return TypeInfo{ .type_var = name };
            if (types.type_name_map.get(name)) |res| return res;
            if (ctx.resolveTypeAlias(name)) |aliased| return aliased;
            return .{ .struct_type = name };
        },
        // ":nil", ":ok" -> atom
        .atom => |name| return TypeInfo{ .atom = name },
        // "(int, string)" -> tuple(@[int, string])
        .tuple => |items| {
            var resolved = try std.ArrayList(TypeInfo).initCapacity(ctx.alloc, items.len);
            errdefer resolved.deinit(ctx.alloc);
            for (items) |item| try resolved.append(ctx.alloc, try evalTypeExpr(ctx, item));
            return TypeInfo{ .tuple = try resolved.toOwnedSlice(ctx.alloc) };
        },
        // "int | :nil" -> union(@[{name="", types=@[int]}, {name="", types=@[:nil]}])
        // "number?" -> union_of(named("number"), atom(":nil")) from parseAtom
        .union_of => |variants| {
            var collected = try std.ArrayList(UnionVariant).initCapacity(ctx.alloc, 4);
            errdefer collected.deinit(ctx.alloc);
            for (variants) |v| {
                const inner = try evalTypeExpr(ctx, v);
                try types.collectVariants(ctx.alloc, inner, &collected);
            }
            return TypeInfo{ .@"union" = try collected.toOwnedSlice(ctx.alloc) };
        },
        // "fn(int) -> bool" -> function(param_types=@[int], return_type=bool)
        .function => |f| {
            var param_types = try std.ArrayList(TypeInfo).initCapacity(ctx.alloc, f.params.len);
            errdefer param_types.deinit(ctx.alloc);
            for (f.params) |p| {
                try param_types.append(ctx.alloc, if (p.type_name) |tn| try evalTypeExpr(ctx, tn) else .any);
            }
            var param_names = try std.ArrayList([]const u8).initCapacity(ctx.alloc, f.params.len);
            errdefer param_names.deinit(ctx.alloc);
            for (f.params) |p| try param_names.append(ctx.alloc, p.name);
            const return_type = if (f.return_type) |rt| try evalTypeExpr(ctx, rt) else .any;
            const sig = try ctx.alloc.create(types.FunctionSignature);
            sig.* = .{
                .param_names = try param_names.toOwnedSlice(ctx.alloc),
                .params = try param_types.toOwnedSlice(ctx.alloc),
                .return_type = return_type,
                .required_count = param_types.items.len,
            };
            return TypeInfo{ .function = sig };
        },
        // "table<int>" -> table(key=null, value=int), "table<string, int>" -> table(key=string, value=int)
        .parameterized => |p| {
            var params = try std.ArrayList(TypeInfo).initCapacity(ctx.alloc, p.params.len);
            errdefer params.deinit(ctx.alloc);
            for (p.params) |param| try params.append(ctx.alloc, try evalTypeExpr(ctx, param));
            const resolved = try params.toOwnedSlice(ctx.alloc);
            if (std.mem.eql(u8, p.name, "table")) {
                if (resolved.len == 1) {
                    const v = try ctx.alloc.create(TypeInfo);
                    v.* = resolved[0];
                    return TypeInfo{ .table = .{ .key = null, .value = v } };
                }
                if (resolved.len == 2) {
                    const k = try ctx.alloc.create(TypeInfo);
                    k.* = resolved[0];
                    const v = try ctx.alloc.create(TypeInfo);
                    v.* = resolved[1];
                    return TypeInfo{ .table = .{ .key = k, .value = v } };
                }
            }
            return .any;
        },
        // "!int" -> union(@[{name=:ok, types=@[int]}, {name=:err, types=@[any]}])
        .error_union => |inner| {
            const t = try evalTypeExpr(ctx, inner);
            const ok_types = try ctx.alloc.dupe(TypeInfo, &.{t});
            const err_types = try ctx.alloc.dupe(TypeInfo, &.{TypeInfo.any});
            const ok_var = UnionVariant{ .name = ":ok", .types = ok_types };
            const err_var = UnionVariant{ .name = ":err", .types = err_types };
            const variants = try ctx.alloc.dupe(UnionVariant, &.{ ok_var, err_var });
            return TypeInfo{ .@"union" = variants };
        },
    }
}
