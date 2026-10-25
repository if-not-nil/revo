//!
//! welcome to type serde
//! , text -> TypeExpr below, typeInfo -> text in printType
//! ; refs flow one way, here -> cst, here -> compiler/types
//!

const cst = @import("cst.zig");
const Lexer = @import("Lexer.zig");
const std = @import("std");
const types = @import("compiler/types.zig");
const TypeInfo = types.TypeInfo;
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;

/// advances pos past consumed tokens
/// parses a type over pre-lexed tokens
/// , one grammar (StreamParser)
/// slices go through `SliceCursor` below
pub fn parseCstTypeExpr(tokens: []const Token, pos: *usize, alloc: std.mem.Allocator) !*cst.CstType {
    var cursor = SliceCursor{ .tokens = tokens, .pos = pos };
    return parseCstTypeExprFromStream(&cursor, alloc);
}

/// slice-backed pull source for pre-lexed token arrays
const SliceCursor = struct {
    tokens: []const Token,
    pos: *usize,

    fn peek(self: *SliceCursor) Token {
        return self.tokens[@min(self.pos.*, self.tokens.len - 1)];
    }
    fn advance(self: *SliceCursor) Token {
        const t = self.peek();
        self.pos.* += 1;
        return t;
    }
    fn check(self: *SliceCursor, t: TokenType) bool {
        return self.peek().type == t;
    }
    fn match(self: *SliceCursor, t: TokenType) bool {
        if (self.check(t)) {
            _ = self.advance();
            return true;
        }
        return false;
    }
    fn peekAt(self: *SliceCursor, ahead: usize) Token {
        return self.tokens[@min(self.pos.* + ahead, self.tokens.len - 1)];
    }
    fn prevToken(self: *SliceCursor) Token {
        if (self.pos.* == 0) return self.peek();
        return self.tokens[@min(self.pos.* - 1, self.tokens.len - 1)];
    }
    fn expect(self: *SliceCursor, t: TokenType) !Token {
        if (self.check(t)) return self.advance();
        return error.UnexpectedToken;
    }
};

pub fn parseCstTypeExprFromStream(stream: anytype, alloc: std.mem.Allocator) !*cst.CstType {
    var p = StreamParser(@TypeOf(stream)){ .stream = stream, .alloc = alloc };
    return try p.parseExpr();
}

fn StreamParser(comptime S: type) type {
    return struct {
        stream: S,
        alloc: std.mem.Allocator,

        fn peek(self: *@This()) Token {
            return self.stream.peek();
        }
        fn advance(self: *@This()) Token {
            return self.stream.advance();
        }
        fn check(self: *@This(), t: TokenType) bool {
            return self.stream.check(t);
        }
        fn match(self: *@This(), t: TokenType) bool {
            return self.stream.match(t);
        }
        fn peekTypeAt(self: *@This(), ahead: usize) TokenType {
            return self.stream.peekAt(ahead).type;
        }
        fn expect(self: *@This(), t: TokenType) !Token {
            return self.stream.expect(t);
        }
        fn prevSpan(self: *@This(), start: Token) Lexer.Span {
            return Lexer.Span.merge(start.span(), self.stream.prevToken().span());
        }

        fn parseExpr(self: *@This()) anyerror!*cst.CstType {
            const first = try self.parseAtom();

            if (!self.check(.bar)) {
                if (self.match(.slash)) {
                    const slash_tok = self.stream.prevToken();
                    const tag = try self.parseAtom();
                    return cst.allocType(self.alloc, Lexer.Span.merge(first.span, tag.span), .{
                        .slashed = .{ .inner = first, .slash_tok = slash_tok, .tag = tag },
                    });
                }
                return first;
            }

            var bars = try std.ArrayList(Token).initCapacity(self.alloc, 2);
            errdefer bars.deinit(self.alloc);

            var rest = try std.ArrayList(*cst.CstType).initCapacity(self.alloc, 4);
            errdefer rest.deinit(self.alloc);

            while (self.match(.bar)) {
                try bars.append(self.alloc, self.stream.prevToken());
                try rest.append(self.alloc, try self.parseAtom());
            }

            const span = Lexer.Span.merge(first.span, self.stream.prevToken().span());
            const node = try cst.allocType(self.alloc, span, .{
                .union_of = .{ .first = first, .bars = try bars.toOwnedSlice(self.alloc), .rest = try rest.toOwnedSlice(self.alloc) },
            });

            if (self.match(.slash)) {
                const slash_tok = self.stream.prevToken();
                const tag = try self.parseAtom();
                return cst.allocType(self.alloc, Lexer.Span.merge(first.span, tag.span), .{
                    .slashed = .{ .inner = node, .slash_tok = slash_tok, .tag = tag },
                });
            }

            return node;
        }

        fn parseAtom(self: *@This()) !*cst.CstType {
            const tok = self.peek();
            switch (tok.type) {
                .ident, .kw_type, .kw_import => {
                    const start = self.advance();
                    const text = start.text;
                    if (std.mem.endsWith(u8, text, "?")) {
                        const inner = try cst.allocType(self.alloc, start.span(), .{ .named = .{ .tok = start } });
                        return cst.allocType(self.alloc, start.span(), .{ .optional = .{ .inner = inner } });
                    }
                    if (self.match(.lt)) {
                        const lt_tok = self.stream.prevToken();
                        var args = try std.ArrayList(*cst.CstType).initCapacity(self.alloc, 4);

                        errdefer args.deinit(self.alloc);
                        var commas = try std.ArrayList(Token).initCapacity(self.alloc, 4);

                        errdefer commas.deinit(self.alloc);
                        try args.append(self.alloc, try self.parseExpr());

                        while (self.match(.comma)) {
                            try commas.append(self.alloc, self.stream.prevToken());
                            try args.append(self.alloc, try self.parseExpr());
                        }

                        const gt_tok = try self.expect(.gt);
                        return cst.allocType(self.alloc, self.prevSpan(start), .{
                            .parameterized = .{
                                .name_tok = start,
                                .lt_tok = lt_tok,
                                .args = try args.toOwnedSlice(self.alloc),
                                .commas = try commas.toOwnedSlice(self.alloc),
                                .gt_tok = gt_tok,
                            },
                        });
                    }

                    if (self.match(.dot)) {
                        const dot_tok = self.stream.prevToken();
                        const name_tok = try self.expect(.ident);

                        if (std.mem.endsWith(u8, name_tok.text, "?")) {
                            return cst.allocType(self.alloc, self.prevSpan(start), .{
                                .qualified_optional = .{ .mod_tok = start, .dot_tok = dot_tok, .name_tok = name_tok },
                            });
                        }

                        return cst.allocType(self.alloc, self.prevSpan(start), .{
                            .qualified = .{ .mod_tok = start, .dot_tok = dot_tok, .name_tok = name_tok },
                        });
                    }

                    return cst.allocType(self.alloc, tok.span(), .{ .named = .{ .tok = start } });
                },
                .atom => {
                    const t = self.advance();
                    return cst.allocType(self.alloc, t.span(), .{ .atom = .{ .tok = t } });
                },
                .kw_fn => {
                    const start = self.advance();

                    var lt_tok: ?Token = null;
                    var tps = try std.ArrayList(Token).initCapacity(self.alloc, 2);

                    errdefer tps.deinit(self.alloc);
                    var tp_commas = try std.ArrayList(Token).initCapacity(self.alloc, 2);

                    errdefer tp_commas.deinit(self.alloc);
                    var gt_tok: ?Token = null;

                    if (self.match(.lt)) {
                        lt_tok = self.stream.prevToken();

                        while (!self.check(.gt)) {
                            const tp_tok = try self.expect(.ident);
                            try tps.append(self.alloc, tp_tok);
                            if (!self.match(.comma)) break;
                            try tp_commas.append(self.alloc, self.stream.prevToken());
                        }

                        gt_tok = try self.expect(.gt);
                    }

                    const lparen_tok = try self.expect(.lparen);
                    const plist = try self.parseFnParams();
                    const rparen_tok = try self.expect(.rparen);

                    var arrow_tok: ?Token = null;
                    var return_type: ?*cst.CstType = null;

                    if (self.match(.arrow)) {
                        arrow_tok = self.stream.prevToken();
                        return_type = try self.parseExpr();
                    }

                    return cst.allocType(self.alloc, self.prevSpan(start), .{
                        .function = .{
                            .fn_tok = start,
                            .lt_tok = lt_tok,
                            .tps = try tps.toOwnedSlice(self.alloc),
                            .tp_commas = try tp_commas.toOwnedSlice(self.alloc),
                            .gt_tok = gt_tok,
                            .lparen_tok = lparen_tok,
                            .params = plist.params,
                            .commas = plist.commas,
                            .rparen_tok = rparen_tok,
                            .arrow_tok = arrow_tok,
                            .ret = return_type,
                        },
                    });
                },
                .lparen => {
                    const lparen_tok = self.advance();
                    const inner = try self.parseExpr();
                    if (self.match(.comma)) return error.UnexpectedToken;

                    const rparen_tok = try self.expect(.rparen);

                    return cst.allocType(self.alloc, self.prevSpan(lparen_tok), .{
                        .paren = .{ .lparen_tok = lparen_tok, .inner = inner, .rparen_tok = rparen_tok },
                    });
                },
                .kw_not, .bang => {
                    const start = self.advance();
                    const inner = try self.parseExpr();

                    return cst.allocType(self.alloc, self.prevSpan(start), .{
                        .error_union = .{ .bang_tok = start, .inner = inner },
                    });
                },
                .lsquiggly => {
                    const start = self.advance();

                    var fields = try std.ArrayList(cst.CstRecordField).initCapacity(self.alloc, 4);
                    errdefer fields.deinit(self.alloc);

                    var commas = try std.ArrayList(Token).initCapacity(self.alloc, 4);
                    errdefer commas.deinit(self.alloc);

                    while (!self.check(.rsquiggly) and !self.check(.eof)) {
                        var field_doc: ?Token = null;
                        while (self.check(.doc_comment)) {
                            field_doc = self.advance();
                        }

                        const cur = self.peek();
                        const is_named = (cur.type == .ident or std.mem.startsWith(u8, @tagName(cur.type), "kw_")) and
                            self.peekTypeAt(1) == .colon;

                        const is_optional = cur.type == .huh and self.peekTypeAt(1) == .ident and self.peekTypeAt(2) == .colon;

                        if (is_optional) {
                            const qmark_tok = self.advance();
                            const name_tok = try self.expect(.ident);
                            const colon_tok = try self.expect(.colon);

                            try fields.append(self.alloc, .{
                                .doc_tok = field_doc,
                                .qmark_tok = qmark_tok,
                                .name_tok = name_tok,
                                .colon_tok = colon_tok,
                                .type = try self.parseExpr(),
                            });
                        } else if (is_named) {
                            const name_tok = self.advance();
                            const colon_tok = try self.expect(.colon);

                            try fields.append(self.alloc, .{
                                .doc_tok = field_doc,
                                .name_tok = name_tok,
                                .colon_tok = colon_tok,
                                .type = try self.parseExpr(),
                            });
                        } else {
                            try fields.append(self.alloc, .{
                                .doc_tok = field_doc,
                                .type = try self.parseExpr(),
                            });
                        }
                        if (!self.match(.comma)) break;
                        try commas.append(self.alloc, self.stream.prevToken());
                    }

                    const rbrace_tok = try self.expect(.rsquiggly);
                    return cst.allocType(self.alloc, self.prevSpan(start), .{
                        .record = .{
                            .lbrace_tok = start,
                            .fields = try fields.toOwnedSlice(self.alloc),
                            .commas = try commas.toOwnedSlice(self.alloc),
                            .rbrace_tok = rbrace_tok,
                        },
                    });
                },
                else => return error.UnexpectedToken,
            }
        }

        const CstParamList = struct { params: []cst.CstTypeParam, commas: []Token };

        fn parseFnParams(self: *@This()) !CstParamList {
            var params = try std.ArrayList(cst.CstTypeParam).initCapacity(self.alloc, 4);
            errdefer params.deinit(self.alloc);

            var commas = try std.ArrayList(Token).initCapacity(self.alloc, 4);
            errdefer commas.deinit(self.alloc);

            while (!self.check(.rparen) and !self.check(.eof)) {
                var param: cst.CstTypeParam = .{ .name_tok = undefined };
                if (self.match(.huh)) param.qmark_tok = self.stream.prevToken();
                const name = self.peek();

                if (name.type != .ident and !std.mem.startsWith(u8, @tagName(name.type), "kw_"))
                    return error.UnexpectedToken;
                param.name_tok = self.advance();

                if (self.match(.colon)) {
                    param.colon_tok = self.stream.prevToken();
                    param.type = try self.parseExpr();
                }

                if (self.match(.dotdot)) {
                    // `...` is two dots; second may be missing on error paths
                    var dots = try std.ArrayList(Token).initCapacity(self.alloc, 2);
                    errdefer dots.deinit(self.alloc);
                    try dots.append(self.alloc, self.stream.prevToken());
                    if (self.match(.dot)) try dots.append(self.alloc, self.stream.prevToken());
                    param.dots = try dots.toOwnedSlice(self.alloc);
                }

                try params.append(self.alloc, param);
                if (!self.match(.comma)) break;

                try commas.append(self.alloc, self.stream.prevToken());
            }
            return .{ .params = try params.toOwnedSlice(self.alloc), .commas = try commas.toOwnedSlice(self.alloc) };
        }
    };
}

/// render a TypeInfo straight to the writer
/// , trailing params past required_count print `?` (for optional)
pub fn printType(ti: TypeInfo, writer: *std.Io.Writer, opts: PrintOptions) !void {
    if (opts.short) {
        switch (ti.tag) {
            .atom => |s| if (s.len == 0)
                try writer.writeAll("atom")
            else if (s[0] == ':')
                try writer.writeAll(s)
            else
                try writer.print(":{s}", .{s}),
            .type_var => |s| try writer.writeAll(s),
            .table => try writer.writeAll("table"),
            .function => try writer.writeAll("function"),
            // all these are spelled out so a future payload-carrying tag breaks
            // , compilation here instead of just printing its tag name
            .bool, .number, .string, .resource, .any, .never, .@"union" => try writer.writeAll(@tagName(ti.tag)),
        }
        return;
    }
    switch (ti.tag) {
        .type_var => |n| try writer.writeAll(n),
        // empty atom payload is the "any atom" sentinel
        .atom => |s| if (s.len == 0) try writer.writeAll("atom") else try writer.print(":{s}", .{cst.atomName(s)}),
        .@"union" => |variants| {
            // `T?`, for a 2-union ending in `:nil`
            if (variants.len == 2 and variants[1].types.len == 1 and variants[1].types[0].tag == .atom and
                std.mem.eql(u8, cst.atomName(variants[1].types[0].tag.atom), "nil"))
            {
                const first = variants[0].types;
                try printType(first[0], writer, opts);

                try writer.writeByte('?');
            } else for (variants, 0..) |v, i| {
                if (i > 0) try writer.writeAll(" | ");
                try printType(v.types[0], writer, opts);
            }
        },
        .table => |tbl| {
            if (tbl.fields) |fields| {
                try writer.writeByte('{');
                for (fields, 0..) |f, i| {
                    if (i > 0) try writer.writeAll(", ");
                    // numeric names are positional array entries
                    const positional = cst.isPositionalName(f.name);
                    if (!positional) {
                        if (f.optional) try writer.writeByte('?');
                        try writer.writeAll(f.name);
                        try writer.writeAll(": ");
                    }

                    try printType(f.field_type, writer, opts);
                    for (opts.values) |p| if (std.mem.eql(u8, p.name, f.name)) {
                        try writer.writeAll(" = ");
                        try writer.writeAll(p.preview);
                        break;
                    };
                }
                try writer.writeByte('}');
            } else if (tbl.key == null and tbl.value.tag == .any) {
                // bare `table` still bare
                // , todo: remove in favour of `{}`
                try writer.writeAll("table");
            } else {
                try writer.writeAll("table<");
                if (tbl.key) |k| {
                    try printType(k.*, writer, opts);
                    try writer.writeAll(", ");
                }

                try printType(tbl.value.*, writer, opts);
                try writer.writeByte('>');
            }
        },
        .function => |sig| {
            try writer.writeAll("fn(");
            for (sig.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                // required params come first, so everything past
                // , required_count is `?`
                if (i >= sig.required_count) try writer.writeByte('?');
                const name = if (i < sig.param_names.len) sig.param_names[i] else "";
                if (name.len > 0) {
                    try writer.writeAll(name);
                    try writer.writeAll(": ");
                }
                try printType(p, writer, opts);
            }
            try writer.writeByte(')');
            try writer.writeAll(" -> ");
            try printType(sig.return_type, writer, opts);
        },
        .bool => try writer.writeAll("bool"),
        .number => try writer.writeAll("number"),
        .string => try writer.writeAll("string"),
        .resource => try writer.writeAll("resource"),
        .any => try writer.writeAll("any"),
        .never => try writer.writeAll("never"),
    }
}

/// short gives single-word tag names
/// , values appends ` = <preview>` per record field (hover)
pub const PrintOptions = struct {
    short: bool = false,
    values: []const FieldPreview = &.{},
};

pub const FieldPreview = struct {
    name: []const u8,
    preview: []const u8,
};

/// formatType with display options (`.short` for tag words, `.values` for hover)
pub fn formatTypeOpts(alloc: std.mem.Allocator, ti: TypeInfo, opts: PrintOptions) std.mem.Allocator.Error![]const u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();

    // allocating writer only fails on oom
    // , printType error set is wider than what happens here
    printType(ti, &buf.writer, opts) catch |err| {
        if (err != error.OutOfMemory) unreachable;
        return error.OutOfMemory;
    };
    return try buf.toOwnedSlice();
}

test "qualified optional type is a nilable union" {
    // `a.b?` used to read as the name `b?`, so `a.b` never resolved
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.lexAt(alloc, "argparse.ResultMsg?");
    var pos: usize = 0;
    const te = try parseCstTypeExpr(tokens, &pos, alloc);

    // `a.B?` stays glued until lowering folds it
    try std.testing.expect(te.kind == .qualified_optional);
    try std.testing.expectEqualStrings("argparse", te.kind.qualified_optional.mod_tok.text);
    // lowering folds it to a nilable union like before
    const ti = try types.evalBare(alloc, te);
    try std.testing.expect(ti.tag == .@"union");
}

test "type serde roundtrips" {
    const cases = [_][]const u8{
        "{number, number, name: string}",
        "{number, :err, atom}",
        "{name: string}",
        "{}",
        "number?",
        "fn() -> string",
        "fn(a: number) -> string",
        "fn(?a: number) -> string",
        "table<string, number>",
        "{user: {name: string}}",
        "{:ok, any}",
        "{:ok, any} | {:err, any}",
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const tokens = try Lexer.lexAt(alloc, c);
        var pos: usize = 0;
        const te = try parseCstTypeExpr(tokens, &pos, alloc);
        const ti = try types.evalBare(alloc, te);
        try std.testing.expectEqualStrings(c, try formatTypeOpts(alloc, ti, .{}));
    }
}
