//!
//! cst? i hardly know her
//!   lossless syntax tree
//!
//! ~ parser builds this, pipeline never sees raw tokens
//! ~ every significant token lives on exactly one node, trivia via `Token`

const std = @import("std");

const Lexer = @import("Lexer.zig");
const Span = Lexer.Span;
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;

/// shared leaf vocabulary (operators, decl kinds, interpolation modes)
/// lives here, not in the lexer: positions originate there, meaning here
pub const discard_name = "_";

pub inline fn isDiscardName(name: []const u8) bool {
    return std.mem.eql(u8, name, discard_name);
}

// they have to match opcode names. thankfully you get a compile error today
pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    int_div,
    mod,
    concat,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    band,
    bor,
    bxor,
    shl,
    shr,
    pow,
    @"union",
};

pub const UnaryOp = enum {
    negate,
    not,
    spawn,
    yield,
};

/// atom payload without a leading colon
/// , `:nil` and `nil` both give `nil`
pub fn atomName(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == ':') name[1..] else name;
}

pub const DeclKind = enum {
    @"const",
    let,
    global,
    /// repl top-level `const`
    /// , todo: add actual "global const" syntax
    global_const,
    test_decl,
    suite_decl,
    type_alias_decl,
    declare_decl,
};

/// `#{expr}` render mode: `:?` debug, `:p` pretty, bare plain
pub const InterpolationMode = enum { plain, debug, pretty };

/// trailing `:v` / `:?` / `:p` interpolation suffix, else null
pub fn interpolationModeSuffix(suffix: []const u8) ?InterpolationMode {
    if (suffix.len != 2 or suffix[0] != ':') return null;
    return switch (suffix[1]) {
        'v' => .plain,
        '?' => .debug,
        'p' => .pretty,
        else => null,
    };
}

/// numeric field names are positional array entries (`{ number, number }`)
pub fn isPositionalName(name: []const u8) bool {
    return name.len > 0 and blk: {
        for (name) |c| if (!std.ascii.isDigit(c)) break :blk false;
        break :blk true;
    };
}

/// leading comment trivia for `tok` out of a retained store
/// , same indexing as `LexOutput.leadingTrivia` but over the root's
/// , own slice, so `fmt` never needs the lexer output alongside the tree
pub fn leadingTriviaFrom(trivia: []const Token, tok: Token) []const Token {
    const end = @min(tok.trivia_start + tok.trivia_len, trivia.len);
    const start = @min(tok.trivia_start, end);
    return trivia[start..end];
}

/// one concrete node; `doc_tok`/`attrs` ride here so no token is lost
pub const CstNode = struct {
    span: Span,
    kind: CstKind,
    doc_tok: ?Token = null,
    attrs: []Token = &.{},
};

/// syntactic forms only, no desugared temps or defaults
pub const CstKind = union(enum) {
    number: struct { tok: Token, value: f64, is_float: bool },
    string: struct { tok: Token },
    interpolated: struct {
        start_tok: Token,
        parts: []CstInterpPart,
        end_tok: ?Token,
        multiline: bool,
    },
    atom: struct { tok: Token },
    ident: struct { tok: Token },
    /// invalid token or recovered gap, lowers to nil
    err: struct { toks: []Token },
    unary: struct { op_tok: Token, op: UnaryOp, expr: *CstNode },
    yield: struct { tok: Token },
    binary: struct { left: *CstNode, op_tok: Token, op: BinOp, right: *CstNode },
    logical: struct { left: *CstNode, op_tok: Token, op: LogicalOp, right: *CstNode },
    compound: struct { target: *CstNode, op_tok: Token, op: BinOp, value: *CstNode },
    assign: struct { target: *CstNode, eq_tok: ?Token, value: *CstNode },
    field: struct { object: *CstNode, dot_tok: Token, name_tok: Token },
    dotted_index: struct { object: *CstNode, dot_tok: Token, num_tok: Token, value: f64 },
    method_call: struct {
        object: *CstNode,
        atom_tok: Token,
        lparen_tok: Token,
        args: []*CstNode,
        commas: []Token,
        rparen_tok: Token,
    },
    index: struct { object: *CstNode, lbracket_tok: Token, key: *CstNode, rbracket_tok: Token },
    generic_call: struct {
        receiver: *CstNode,
        lt_tok: Token,
        type_args: []Token,
        commas: []Token,
        gt_tok: Token,
        lparen_tok: Token,
        args: []*CstNode,
        arg_commas: []Token,
        rparen_tok: Token,
    },
    call: struct {
        callee: *CstNode,
        lparen_tok: Token,
        args: []*CstNode,
        commas: []Token,
        rparen_tok: Token,
    },
    bare_call: struct { callee: *CstNode, arg: *CstNode },
    range: struct {
        start: *CstNode,
        dot1_tok: Token,
        mid: *CstNode,
        dot2_tok: ?Token,
        end: ?*CstNode,
    },
    for_range: struct {
        start: ?*CstNode,
        dot1_tok: Token,
        mid: ?*CstNode,
        dot2_tok: ?Token,
        end: ?*CstNode,
    },
    slice: struct {
        lbracket_tok: ?Token,
        start: ?*CstNode,
        dots: []Token,
        mid: ?*CstNode,
        end: ?*CstNode,
        rbracket_tok: ?Token,
        /// superseded middles (`[a..b..c..d]` drops `b`); retained, not lowered
        dropped: []*CstNode = &.{},
    },
    pipe: struct { left: *CstNode, pipe_tok: Token, right: *CstNode },
    try_expr: struct { expr: *CstNode, qmark_tok: Token },
    if_expr: struct {
        kw_tok: Token,
        unless: bool,
        cond: *CstNode,
        then: *CstNode,
        else_tok: ?Token,
        else_: ?*CstNode,
    },
    match: struct { kw_tok: Token, subject: ?*CstNode, bars: []Token, arms: []CstArm },
    ascribed: struct { expr: *CstNode, colon_tok: Token, type: *CstType },
    table: struct {
        lbrace_tok: Token,
        entries: []CstEntry,
        commas: []Token,
        rbrace_tok: Token,
    },
    paren: struct { lparen_tok: Token, expr: ?*CstNode, rparen_tok: Token },
    block: struct { stmts: []*CstNode, semis: []Token },
    do_block: struct {
        do_tok: Token,
        slash_tok: ?Token,
        label_tok: ?Token,
        stmts: []*CstNode,
        semis: []Token,
        end_tok: Token,
    },
    root: struct {
        stmts: []*CstNode,
        semis: []Token,
        eof_tok: Token,
        /// file trivia (comments) in source order; tokens point into it
        /// via `trivia_start`/`trivia_len`. only the parse root carries it;
        /// , everything downstream must preserve it when rebuilding roots
        /// , empty for pre-lexed parses and synthesized trees
        /// , this is what makes `fmt` lossless like `go fmt`
        trivia: []Token = &.{},
    },
    fn_def: struct {
        /// null for named defs; the binding owns the keyword there
        fn_tok: ?Token,
        head: FnHead,
        kind: DeclKind,
        lt_tok: ?Token,
        type_params: []Token,
        tp_commas: []Token,
        gt_tok: ?Token,
        lparen_tok: Token,
        params: []CstParam,
        commas: []Token,
        rparen_tok: Token,
        arrow_tok: ?Token,
        return_type: ?*CstType,
        body: *CstNode,
    },
    /// `fn obj:m() body` / `fn obj.m() body`; single node keeps source order
    /// , lowers to index assign with implicit self like before
    fn_method: struct {
        fn_tok: Token,
        head: FnHead,
        lt_tok: ?Token,
        type_params: []Token,
        tp_commas: []Token,
        gt_tok: ?Token,
        lparen_tok: Token,
        params: []CstParam,
        commas: []Token,
        rparen_tok: Token,
        arrow_tok: ?Token,
        return_type: ?*CstType,
        body: *CstNode,
    },
    binding: struct {
        kind_tok: Token,
        kind: DeclKind,
        target: *CstNode,
        colon_tok: ?Token,
        type: ?*CstType,
        eq_tok: ?Token,
        value: *CstNode,
    },
    decl: struct { pub_tok: ?Token, kind: DeclKind, inner: *CstNode, pub_: bool = false },
    import: struct {
        import_tok: Token,
        lbrace_tok: ?Token,
        items: []CstImportItem,
        commas: []Token,
        rbrace_tok: ?Token,
        pub_: bool,
    },
    test_block: struct {
        kw_tok: Token,
        slash_tok: ?Token,
        skip_tok: ?Token,
        name: StringLit,
        body: *CstNode,
    },
    test_suite: struct { kw_tok: Token, name: StringLit, body: *CstNode },
    type_alias: struct {
        kw_tok: Token,
        /// all head segments starting with the name; dotted iff len > 1
        segs: []Token,
        dots: []Token,
        lt_tok: ?Token,
        tps: []Token,
        tp_commas: []Token,
        gt_tok: ?Token,
        eq_tok: Token,
        type: *CstType,
    },
    for_loop: struct {
        for_tok: Token,
        slash_tok: ?Token,
        label_tok: ?Token,
        params: []Token,
        commas: []Token,
        in_tok: Token,
        iter: *CstNode,
        body: *CstNode,
    },
    while_loop: struct {
        kw_tok: Token,
        slash_tok: ?Token,
        label_tok: ?Token,
        pred: *CstNode,
        body: *CstNode,
    },
    loop_expr: struct { kw_tok: Token, slash_tok: ?Token, label_tok: ?Token, body: *CstNode },
    break_expr: struct { kw_tok: Token, slash_tok: ?Token, label_tok: ?Token, value: ?*CstNode },
    continue_expr: struct { kw_tok: Token, slash_tok: ?Token, label_tok: ?Token },
    return_expr: struct { kw_tok: Token, value: ?*CstNode },
    comp_block: struct { kw_tok: Token, expr: *CstNode },
};

/// `and`/`or`/`orelse` share one shape
pub const LogicalOp = enum { and_op, or_op, orelse_op };

/// named, dotted, and method fn heads
/// , `named` borrows text only; the binding target owns the token
pub const FnHead = union(enum) {
    anon,
    named: struct { name: []const u8, name_span: Span },
    method_colon: struct { obj_tok: Token, atom_tok: Token },
    method_dot: struct { obj_tok: Token, dot_tok: Token, name_tok: Token },
};

/// one interpolated segment; literal text borrows the part token
pub const CstInterpPart = union(enum) {
    literal: Token,
    interp: struct {
        open_tok: Token,
        value: *CstNode,
        mode: InterpolationMode,
        mode_tok: ?Token,
        close_tok: Token,
    },
};

/// `name`, `?name: T = default`
pub const CstParam = struct {
    name_tok: Token,
    qmark_tok: ?Token = null,
    colon_tok: ?Token = null,
    type: ?*CstType = null,
    eq_tok: ?Token = null,
    default: ?*CstNode = null,
};

/// table entries keep their own delimiters
/// , `e: Type` is just a bare ascribed value
pub const CstEntry = union(enum) {
    computed: struct {
        lbracket_tok: Token,
        key: *CstNode,
        rbracket_tok: Token,
        eq_tok: Token,
        value: *CstNode,
    },
    keyed: struct { key: *CstNode, eq_tok: Token, value: *CstNode },
    bare: struct { value: *CstNode },
};

/// `pat [, pat]* [when g] => e`
pub const CstArm = struct {
    matchers: []CstMatcher,
    commas: []Token,
    when_tok: ?Token,
    guard: ?*CstNode,
    arrow_tok: Token,
    then: *CstNode,
};

/// `_` or a pattern expr
pub const CstMatcher = union(enum) {
    wildcard: Token,
    expr: *CstNode,
};

/// import item; `name =` absent means autobind
pub const CstImportItem = struct {
    name_tok: ?Token,
    eq_tok: ?Token,
    path: StringLit,
    span: Span,
    pub_: bool = false,
};

/// dotted head for `declare`/`type` plus optional type params
pub const DeclareHead = struct {
    dots: []Token = &.{},
    segs: []Token = &.{},
    lt_tok: ?Token = null,
    tps: []Token = &.{},
    tp_commas: []Token = &.{},
    gt_tok: ?Token = null,
};

/// decoded string text plus span plus consumed tokens
pub const StringLit = struct {
    text: []const u8,
    span: Span,
    toks: []Token = &.{},
};

/// comma-separated exprs plus separators
pub const CstList = struct {
    items: []*CstNode = &.{},
    commas: []Token = &.{},
};

/// value params plus separators
pub const ParamList = struct {
    params: []CstParam = &.{},
    commas: []Token = &.{},
};

/// stmts plus `;` separators
pub const CstBlock = struct {
    stmts: []*CstNode = &.{},
    semis: []Token = &.{},
};

/// lossless type syntax; sugar folds at use sites
pub const CstType = struct {
    span: Span,
    kind: CstTypeKind,
};

/// every delimiter retained; sugar (`?`, parens, `/tag`) folds in lowering
pub const CstTypeKind = union(enum) {
    named: struct { tok: Token },
    atom: struct { tok: Token },
    union_of: struct { first: *CstType, bars: []Token, rest: []*CstType },
    /// `T?` suffix; the `?` rides glued on the name token
    optional: struct { inner: *CstType },
    parameterized: struct {
        name_tok: Token,
        lt_tok: Token,
        args: []*CstType,
        commas: []Token,
        gt_tok: Token,
    },
    qualified: struct { mod_tok: Token, dot_tok: Token, name_tok: Token },
    /// `a.B?` with glued `?`; lowers to a nilable union
    qualified_optional: struct { mod_tok: Token, dot_tok: Token, name_tok: Token },
    function: struct {
        fn_tok: Token,
        lt_tok: ?Token,
        tps: []Token,
        tp_commas: []Token,
        gt_tok: ?Token,
        lparen_tok: Token,
        params: []CstTypeParam,
        commas: []Token,
        rparen_tok: Token,
        arrow_tok: ?Token,
        ret: ?*CstType,
    },
    paren: struct { lparen_tok: Token, inner: *CstType, rparen_tok: Token },
    error_union: struct { bang_tok: Token, inner: *CstType },
    record: struct {
        lbrace_tok: Token,
        fields: []CstRecordField,
        commas: []Token,
        rbrace_tok: Token,
    },
    slashed: struct { inner: *CstType, slash_tok: Token, tag: *CstType },
};

/// type-level param; `...` is 1-2 trailing dots
pub const CstTypeParam = struct {
    qmark_tok: ?Token = null,
    name_tok: Token,
    colon_tok: ?Token = null,
    type: ?*CstType = null,
    dots: []Token = &.{},
};

/// record field; absent name means positional
pub const CstRecordField = struct {
    doc_tok: ?Token = null,
    qmark_tok: ?Token = null,
    name_tok: ?Token = null,
    colon_tok: ?Token = null,
    type: *CstType,
};

/// span over cst children or fallback when empty
pub fn spanFromNodes(items: []const *CstNode, fallback: Span) Span {
    if (items.len == 0) return fallback;
    return Span.merge(items[0].span, items[items.len - 1].span);
}

/// alloc one cst node
pub fn allocNode(allocator: std.mem.Allocator, span: Span, kind: CstKind) std.mem.Allocator.Error!*CstNode {
    const node = try allocator.create(CstNode);
    node.* = .{ .span = span, .kind = kind };
    return node;
}

/// alloc one cst type
pub fn allocType(allocator: std.mem.Allocator, span: Span, kind: CstTypeKind) std.mem.Allocator.Error!*CstType {
    const te = try allocator.create(CstType);
    te.* = .{ .span = span, .kind = kind };
    return te;
}

// -- [tokens] --------------------------------------------------------------
//
// every significant token on exactly one node, in source order
// , tooling walks this instead of rescanning source

/// append one optional token
fn putTok(out: *std.ArrayList(Token), alloc: std.mem.Allocator, tok: ?Token) !void {
    if (tok) |t| try out.append(alloc, t);
}

/// append items zipped with their trailing separators
fn putZipped(
    out: *std.ArrayList(Token),
    alloc: std.mem.Allocator,
    nodes: []*CstNode,
    seps: []Token,
    walk: *const fn (*std.ArrayList(Token), std.mem.Allocator, *CstNode) std.mem.Allocator.Error!void,
) !void {
    for (nodes, 0..) |node, i| {
        try walk(out, alloc, node);
        if (i < seps.len) try out.append(alloc, seps[i]);
    }
    if (seps.len > nodes.len) {
        for (seps[nodes.len..]) |sep| try out.append(alloc, sep);
    }
}

/// all significant tokens owned by `node` in source order
pub fn retainedTokens(alloc: std.mem.Allocator, node: *CstNode) std.mem.Allocator.Error![]Token {
    var out = std.ArrayList(Token).empty;
    errdefer out.deinit(alloc);
    try walkTokens(&out, alloc, node);
    return out.toOwnedSlice(alloc);
}

fn walkTokens(out: *std.ArrayList(Token), alloc: std.mem.Allocator, node: *CstNode) std.mem.Allocator.Error!void {
    if (node.doc_tok) |t| try out.append(alloc, t);
    for (node.attrs) |t| try out.append(alloc, t);
    switch (node.kind) {
        .number => |n| try out.append(alloc, n.tok),
        .string => |s| try out.append(alloc, s.tok),
        .atom => |a| try out.append(alloc, a.tok),
        .ident => |i| try out.append(alloc, i.tok),
        .err => |e| try out.appendSlice(alloc, e.toks),
        .yield => |y| try out.append(alloc, y.tok),
        .unary => |u| {
            try out.append(alloc, u.op_tok);
            try walkTokens(out, alloc, u.expr);
        },
        .binary => |b| {
            try walkTokens(out, alloc, b.left);
            try out.append(alloc, b.op_tok);
            try walkTokens(out, alloc, b.right);
        },
        .logical => |l| {
            try walkTokens(out, alloc, l.left);
            try out.append(alloc, l.op_tok);
            try walkTokens(out, alloc, l.right);
        },
        .compound => |c| {
            try walkTokens(out, alloc, c.target);
            try out.append(alloc, c.op_tok);
            try walkTokens(out, alloc, c.value);
        },
        .assign => |a| {
            try walkTokens(out, alloc, a.target);
            try putTok(out, alloc, a.eq_tok);
            try walkTokens(out, alloc, a.value);
        },
        .field => |f| {
            try walkTokens(out, alloc, f.object);
            try out.append(alloc, f.dot_tok);
            try out.append(alloc, f.name_tok);
        },
        .dotted_index => |d| {
            try walkTokens(out, alloc, d.object);
            try out.append(alloc, d.dot_tok);
            try out.append(alloc, d.num_tok);
        },
        .method_call => |m| {
            try walkTokens(out, alloc, m.object);
            try out.append(alloc, m.atom_tok);
            try out.append(alloc, m.lparen_tok);
            try putZipped(out, alloc, m.args, m.commas, walkTokens);
            try out.append(alloc, m.rparen_tok);
        },
        .index => |ix| {
            try walkTokens(out, alloc, ix.object);
            try out.append(alloc, ix.lbracket_tok);
            try walkTokens(out, alloc, ix.key);
            try out.append(alloc, ix.rbracket_tok);
        },
        .generic_call => |g| {
            try walkTokens(out, alloc, g.receiver);
            try out.append(alloc, g.lt_tok);
            for (g.type_args, 0..) |t, i| {
                try out.append(alloc, t);
                if (i < g.commas.len) try out.append(alloc, g.commas[i]);
            }
            if (g.commas.len > g.type_args.len) {
                for (g.commas[g.type_args.len..]) |t| try out.append(alloc, t);
            }
            try out.append(alloc, g.gt_tok);
            try out.append(alloc, g.lparen_tok);
            try putZipped(out, alloc, g.args, g.arg_commas, walkTokens);
            try out.append(alloc, g.rparen_tok);
        },
        .call => |c| {
            try walkTokens(out, alloc, c.callee);
            try out.append(alloc, c.lparen_tok);
            try putZipped(out, alloc, c.args, c.commas, walkTokens);
            try out.append(alloc, c.rparen_tok);
        },
        .bare_call => |b| {
            try walkTokens(out, alloc, b.callee);
            try walkTokens(out, alloc, b.arg);
        },
        .range => |r| {
            try walkTokens(out, alloc, r.start);
            try out.append(alloc, r.dot1_tok);
            try walkTokens(out, alloc, r.mid);
            if (r.dot2_tok) |t| try out.append(alloc, t);
            if (r.end) |e| try walkTokens(out, alloc, e);
        },
        .for_range => |r| {
            if (r.start) |s| try walkTokens(out, alloc, s);
            try out.append(alloc, r.dot1_tok);
            if (r.mid) |m| try walkTokens(out, alloc, m);
            if (r.dot2_tok) |t| try out.append(alloc, t);
            if (r.end) |e| try walkTokens(out, alloc, e);
        },
        .slice => |s| {
            if (s.lbracket_tok) |t| try out.append(alloc, t);
            if (s.start) |n| try walkTokens(out, alloc, n);
            // dots interleave bounds; dropped middles walk after, order kept per node
            try out.appendSlice(alloc, s.dots);
            if (s.mid) |n| try walkTokens(out, alloc, n);
            if (s.end) |n| try walkTokens(out, alloc, n);
            for (s.dropped) |n| try walkTokens(out, alloc, n);
            if (s.rbracket_tok) |t| try out.append(alloc, t);
        },
        .pipe => |p| {
            try walkTokens(out, alloc, p.left);
            try out.append(alloc, p.pipe_tok);
            try walkTokens(out, alloc, p.right);
        },
        .try_expr => |t| {
            try walkTokens(out, alloc, t.expr);
            try out.append(alloc, t.qmark_tok);
        },
        .if_expr => |c| {
            try out.append(alloc, c.kw_tok);
            try walkTokens(out, alloc, c.cond);
            try walkTokens(out, alloc, c.then);
            if (c.else_tok) |t| try out.append(alloc, t);
            if (c.else_) |e| try walkTokens(out, alloc, e);
        },
        .match => |m| {
            try out.append(alloc, m.kw_tok);
            if (m.subject) |s| try walkTokens(out, alloc, s);
            for (m.arms, 0..) |arm, ai| {
                if (ai < m.bars.len) try out.append(alloc, m.bars[ai]);
                for (arm.matchers, 0..) |mc, i| {
                    switch (mc) {
                        .wildcard => |t| try out.append(alloc, t),
                        .expr => |e| try walkTokens(out, alloc, e),
                    }
                    if (i < arm.commas.len) try out.append(alloc, arm.commas[i]);
                }
                if (arm.when_tok) |t| try out.append(alloc, t);
                if (arm.guard) |g| try walkTokens(out, alloc, g);
                try out.append(alloc, arm.arrow_tok);
                try walkTokens(out, alloc, arm.then);
            }
        },
        .ascribed => |a| {
            try walkTokens(out, alloc, a.expr);
            try out.append(alloc, a.colon_tok);
            try walkTypeTokens(out, alloc, a.type);
        },
        .table => |t| {
            try out.append(alloc, t.lbrace_tok);
            for (t.entries, 0..) |entry, i| {
                switch (entry) {
                    .computed => |c| {
                        try out.append(alloc, c.lbracket_tok);
                        try walkTokens(out, alloc, c.key);
                        try out.append(alloc, c.rbracket_tok);
                        try out.append(alloc, c.eq_tok);
                        try walkTokens(out, alloc, c.value);
                    },
                    .keyed => |k| {
                        try walkTokens(out, alloc, k.key);
                        try out.append(alloc, k.eq_tok);
                        try walkTokens(out, alloc, k.value);
                    },
                    .bare => |b| try walkTokens(out, alloc, b.value),
                }
                if (i < t.commas.len) try out.append(alloc, t.commas[i]);
            }
            try out.append(alloc, t.rbrace_tok);
        },
        .paren => |p| {
            try out.append(alloc, p.lparen_tok);
            if (p.expr) |e| try walkTokens(out, alloc, e);
            try out.append(alloc, p.rparen_tok);
        },
        .block => |b| {
            for (b.stmts, 0..) |s, i| {
                try walkTokens(out, alloc, s);
                if (i < b.semis.len) try out.append(alloc, b.semis[i]);
            }
            if (b.semis.len > b.stmts.len) {
                for (b.semis[b.stmts.len..]) |t| try out.append(alloc, t);
            }
        },
        .do_block => |d| {
            try out.append(alloc, d.do_tok);
            if (d.slash_tok) |t| try out.append(alloc, t);
            if (d.label_tok) |t| try out.append(alloc, t);
            for (d.stmts, 0..) |s, i| {
                try walkTokens(out, alloc, s);
                if (i < d.semis.len) try out.append(alloc, d.semis[i]);
            }
            if (d.semis.len > d.stmts.len) {
                for (d.semis[d.stmts.len..]) |t| try out.append(alloc, t);
            }
            try out.append(alloc, d.end_tok);
        },
        .root => |r| {
            for (r.stmts, 0..) |s, i| {
                try walkTokens(out, alloc, s);
                if (i < r.semis.len) try out.append(alloc, r.semis[i]);
            }
            if (r.semis.len > r.stmts.len) {
                for (r.semis[r.stmts.len..]) |t| try out.append(alloc, t);
            }
            try out.append(alloc, r.eof_tok);
        },
        .fn_def => |f| {
            if (f.fn_tok) |t| try out.append(alloc, t);
            switch (f.head) {
                .anon, .named => {},
                .method_colon, .method_dot => unreachable,
            }
            try walkFnTail(out, alloc, .{
                .lt_tok = f.lt_tok,
                .tps = f.type_params,
                .tp_commas = f.tp_commas,
                .gt_tok = f.gt_tok,
                .lparen_tok = f.lparen_tok,
                .params = f.params,
                .commas = f.commas,
                .rparen_tok = f.rparen_tok,
                .arrow_tok = f.arrow_tok,
                .return_type = f.return_type,
                .body = f.body,
            });
        },
        .fn_method => |f| {
            try out.append(alloc, f.fn_tok);
            switch (f.head) {
                .anon, .named => unreachable,
                .method_colon => |m| {
                    try out.append(alloc, m.obj_tok);
                    try out.append(alloc, m.atom_tok);
                },
                .method_dot => |m| {
                    try out.append(alloc, m.obj_tok);
                    try out.append(alloc, m.dot_tok);
                    try out.append(alloc, m.name_tok);
                },
            }
            try walkFnTail(out, alloc, .{
                .lt_tok = f.lt_tok,
                .tps = f.type_params,
                .tp_commas = f.tp_commas,
                .gt_tok = f.gt_tok,
                .lparen_tok = f.lparen_tok,
                .params = f.params,
                .commas = f.commas,
                .rparen_tok = f.rparen_tok,
                .arrow_tok = f.arrow_tok,
                .return_type = f.return_type,
                .body = f.body,
            });
        },
        .binding => |b| {
            try out.append(alloc, b.kind_tok);
            try walkTokens(out, alloc, b.target);
            if (b.colon_tok) |t| try out.append(alloc, t);
            if (b.type) |t| try walkTypeTokens(out, alloc, t);
            if (b.eq_tok) |t| try out.append(alloc, t);
            try walkTokens(out, alloc, b.value);
        },
        .decl => |d| {
            if (d.pub_tok) |t| try out.append(alloc, t);
            try walkTokens(out, alloc, d.inner);
        },
        .import => |im| {
            try out.append(alloc, im.import_tok);
            if (im.lbrace_tok) |t| try out.append(alloc, t);
            for (im.items, 0..) |item, i| {
                if (item.name_tok) |t| try out.append(alloc, t);
                if (item.eq_tok) |t| try out.append(alloc, t);
                try out.appendSlice(alloc, item.path.toks);
                if (i < im.commas.len) try out.append(alloc, im.commas[i]);
            }
            if (im.rbrace_tok) |t| try out.append(alloc, t);
        },
        .test_block => |t| {
            try out.append(alloc, t.kw_tok);
            if (t.slash_tok) |tok| try out.append(alloc, tok);
            if (t.skip_tok) |tok| try out.append(alloc, tok);
            try out.appendSlice(alloc, t.name.toks);
            try walkTokens(out, alloc, t.body);
        },
        .test_suite => |t| {
            try out.append(alloc, t.kw_tok);
            try out.appendSlice(alloc, t.name.toks);
            try walkTokens(out, alloc, t.body);
        },
        .type_alias => |t| {
            try out.append(alloc, t.kw_tok);
            for (t.segs, 0..) |seg, i| {
                try out.append(alloc, seg);
                if (i < t.dots.len) try out.append(alloc, t.dots[i]);
            }
            if (t.lt_tok) |tok| try out.append(alloc, tok);
            for (t.tps, 0..) |tok, i| {
                try out.append(alloc, tok);
                if (i < t.tp_commas.len) try out.append(alloc, t.tp_commas[i]);
            }
            if (t.gt_tok) |tok| try out.append(alloc, tok);
            try out.append(alloc, t.eq_tok);
            try walkTypeTokens(out, alloc, t.type);
        },
        .for_loop => |f| {
            try out.append(alloc, f.for_tok);
            if (f.slash_tok) |t| try out.append(alloc, t);
            if (f.label_tok) |t| try out.append(alloc, t);
            for (f.params, 0..) |t, i| {
                try out.append(alloc, t);
                if (i < f.commas.len) try out.append(alloc, f.commas[i]);
            }
            try out.append(alloc, f.in_tok);
            try walkTokens(out, alloc, f.iter);
            try walkTokens(out, alloc, f.body);
        },
        .while_loop => |w| {
            try out.append(alloc, w.kw_tok);
            if (w.slash_tok) |t| try out.append(alloc, t);
            if (w.label_tok) |t| try out.append(alloc, t);
            try walkTokens(out, alloc, w.pred);
            try walkTokens(out, alloc, w.body);
        },
        .loop_expr => |l| {
            try out.append(alloc, l.kw_tok);
            if (l.slash_tok) |t| try out.append(alloc, t);
            if (l.label_tok) |t| try out.append(alloc, t);
            try walkTokens(out, alloc, l.body);
        },
        .break_expr => |b| {
            try out.append(alloc, b.kw_tok);
            if (b.slash_tok) |t| try out.append(alloc, t);
            if (b.label_tok) |t| try out.append(alloc, t);
            if (b.value) |v| try walkTokens(out, alloc, v);
        },
        .continue_expr => |c| {
            try out.append(alloc, c.kw_tok);
            if (c.slash_tok) |t| try out.append(alloc, t);
            if (c.label_tok) |t| try out.append(alloc, t);
        },
        .return_expr => |r| {
            try out.append(alloc, r.kw_tok);
            if (r.value) |v| try walkTokens(out, alloc, v);
        },
        .comp_block => |c| {
            try out.append(alloc, c.kw_tok);
            try walkTokens(out, alloc, c.expr);
        },
        .interpolated => |t| {
            try out.append(alloc, t.start_tok);
            for (t.parts) |part| switch (part) {
                .literal => |tok| try out.append(alloc, tok),
                .interp => |in| {
                    try out.append(alloc, in.open_tok);
                    try walkTokens(out, alloc, in.value);
                    if (in.mode_tok) |tok| try out.append(alloc, tok);
                    try out.append(alloc, in.close_tok);
                },
            };
            if (t.end_tok) |tok| try out.append(alloc, tok);
        },
    }
}

/// shared tail of both fn forms: generics, params, return, body
const FnTail = struct {
    lt_tok: ?Token,
    tps: []Token,
    tp_commas: []Token,
    gt_tok: ?Token,
    lparen_tok: Token,
    params: []CstParam,
    commas: []Token,
    rparen_tok: Token,
    arrow_tok: ?Token,
    return_type: ?*CstType,
    body: *CstNode,
};

fn walkFnTail(out: *std.ArrayList(Token), alloc: std.mem.Allocator, f: FnTail) std.mem.Allocator.Error!void {
    if (f.lt_tok) |t| try out.append(alloc, t);
    for (f.tps, 0..) |t, i| {
        try out.append(alloc, t);
        if (i < f.tp_commas.len) try out.append(alloc, f.tp_commas[i]);
    }
    if (f.gt_tok) |t| try out.append(alloc, t);
    try out.append(alloc, f.lparen_tok);
    for (f.params, 0..) |p, i| {
        if (p.qmark_tok) |t| try out.append(alloc, t);
        try out.append(alloc, p.name_tok);
        if (p.colon_tok) |t| try out.append(alloc, t);
        if (p.type) |t| try walkTypeTokens(out, alloc, t);
        if (p.eq_tok) |t| try out.append(alloc, t);
        if (p.default) |d| try walkTokens(out, alloc, d);
        if (i < f.commas.len) try out.append(alloc, f.commas[i]);
    }
    try out.append(alloc, f.rparen_tok);
    if (f.arrow_tok) |t| try out.append(alloc, t);
    if (f.return_type) |t| try walkTypeTokens(out, alloc, t);
    try walkTokens(out, alloc, f.body);
}

/// all significant tokens owned by a type in source order
fn walkTypeTokens(out: *std.ArrayList(Token), alloc: std.mem.Allocator, t: *CstType) std.mem.Allocator.Error!void {
    switch (t.kind) {
        .named => |n| try out.append(alloc, n.tok),
        .atom => |a| try out.append(alloc, a.tok),
        .union_of => |u| {
            try walkTypeTokens(out, alloc, u.first);
            for (u.rest, 0..) |r, i| {
                if (i < u.bars.len) try out.append(alloc, u.bars[i]);
                try walkTypeTokens(out, alloc, r);
            }
            if (u.bars.len > u.rest.len) {
                for (u.bars[u.rest.len..]) |tok| try out.append(alloc, tok);
            }
        },
        .optional => |o| try walkTypeTokens(out, alloc, o.inner),
        .parameterized => |p| {
            try out.append(alloc, p.name_tok);
            try out.append(alloc, p.lt_tok);
            for (p.args, 0..) |a, i| {
                try walkTypeTokens(out, alloc, a);
                if (i < p.commas.len) try out.append(alloc, p.commas[i]);
            }
            try out.append(alloc, p.gt_tok);
        },
        .qualified => |q| {
            try out.append(alloc, q.mod_tok);
            try out.append(alloc, q.dot_tok);
            try out.append(alloc, q.name_tok);
        },
        .qualified_optional => |q| {
            try out.append(alloc, q.mod_tok);
            try out.append(alloc, q.dot_tok);
            try out.append(alloc, q.name_tok);
        },
        .function => |f| {
            try out.append(alloc, f.fn_tok);
            if (f.lt_tok) |tok| try out.append(alloc, tok);
            for (f.tps, 0..) |tok, i| {
                try out.append(alloc, tok);
                if (i < f.tp_commas.len) try out.append(alloc, f.tp_commas[i]);
            }
            if (f.gt_tok) |tok| try out.append(alloc, tok);
            try out.append(alloc, f.lparen_tok);
            for (f.params, 0..) |p, i| {
                if (p.qmark_tok) |tok| try out.append(alloc, tok);
                try out.append(alloc, p.name_tok);
                if (p.colon_tok) |tok| try out.append(alloc, tok);
                if (p.type) |ty| try walkTypeTokens(out, alloc, ty);
                try out.appendSlice(alloc, p.dots);
                if (i < f.commas.len) try out.append(alloc, f.commas[i]);
            }
            try out.append(alloc, f.rparen_tok);
            if (f.arrow_tok) |tok| try out.append(alloc, tok);
            if (f.ret) |r| try walkTypeTokens(out, alloc, r);
        },
        .paren => |p| {
            try out.append(alloc, p.lparen_tok);
            try walkTypeTokens(out, alloc, p.inner);
            try out.append(alloc, p.rparen_tok);
        },
        .error_union => |e| {
            try out.append(alloc, e.bang_tok);
            try walkTypeTokens(out, alloc, e.inner);
        },
        .record => |r| {
            try out.append(alloc, r.lbrace_tok);
            for (r.fields, 0..) |f, i| {
                if (f.doc_tok) |tok| try out.append(alloc, tok);
                if (f.qmark_tok) |tok| try out.append(alloc, tok);
                if (f.name_tok) |tok| try out.append(alloc, tok);
                if (f.colon_tok) |tok| try out.append(alloc, tok);
                try walkTypeTokens(out, alloc, f.type);
                if (i < r.commas.len) try out.append(alloc, r.commas[i]);
            }
            try out.append(alloc, r.rbrace_tok);
        },
        .slashed => |s| {
            try walkTypeTokens(out, alloc, s.inner);
            try out.append(alloc, s.slash_tok);
            try walkTypeTokens(out, alloc, s.tag);
        },
    }
}

// -- [cst-only helpers] ------------------------------------------------------
//
// semantic constructors + walkers over `CstNode` directly, no `ast` lowering
// downstream (semantic/compiler/pipeline) uses these

/// ident text of a (possibly parenthesized) node, null otherwise
/// , one shared helper for scope/type/codegen ident checks
pub fn identText(node: *const CstNode) ?[]const u8 {
    const unwrapped = unwrapParen(node) orelse return null;
    if (unwrapped.kind == .ident) return unwrapped.kind.ident.tok.text;
    return null;
}

/// value of a `name = v` named call arg, null otherwise
pub fn namedArgValue(arg: *const CstNode) ?*const CstNode {
    const au = unwrapParen(arg) orelse return null;
    if (au.kind != .assign) return null;
    const tu = unwrapParen(au.kind.assign.target) orelse return null;
    if (tu.kind != .ident) return null;
    return au.kind.assign.value;
}

/// name of a `name = v` named call arg, null otherwise
pub fn namedArgName(arg: *const CstNode) ?[]const u8 {
    const au = unwrapParen(arg) orelse return null;
    if (au.kind != .assign) return null;
    return identText(au.kind.assign.target);
}

/// token texts borrowed as an owned slice (generic type-param lists)
pub fn tokenTexts(alloc: std.mem.Allocator, toks: []const Token) std.mem.Allocator.Error![]const []const u8 {
    const out = try alloc.alloc([]const u8, toks.len);
    for (toks, out) |tok, *dst| dst.* = tok.text;
    return out;
}

/// bare member name of a type alias: last head segment
pub fn aliasName(t: @FieldType(CstKind, "type_alias")) []const u8 {
    return t.segs[t.segs.len - 1].text;
}

/// true when a target is a keyless destructure table
pub fn isTablePattern(node: *const CstNode) bool {
    return patternBareEntries(node) != null;
}

/// bare values of a keyless table in order; null when keyed/computed present
pub fn patternBareEntries(node: *const CstNode) ?[]const CstEntry {
    const u = unwrapParen(node) orelse return null;
    if (u.kind != .table) return null;
    for (u.kind.table.entries) |entry| {
        if (entry != .bare) return null;
    }
    return u.kind.table.entries;
}

/// label text or null when no `/label`
pub fn labelText(tok: ?Token) ?[]const u8 {
    return if (tok) |t| t.text else null;
}

/// trimmed doc text or null (docs ride outermost on the node)
pub fn trimmedDocText(tok: ?Token) ?[]const u8 {
    const t = tok orelse return null;
    return std.mem.trim(u8, t.text, " \t\n\r");
}

/// fake token for synthesized nodes
/// text borrowed, span explicit, type defaults to ident, trivia empty
pub fn syntheticToken(text: []const u8, span: Span) Token {
    return .{
        .type = .ident,
        .text = text,
        .line = span.line,
        .column = span.column,
        .start = span.start,
        .end = span.end,
    };
}

/// freshly built, unpublished nodes only
/// trees are immutable after publish
pub fn attachDoc(node: *CstNode, tok: Token) void {
    node.doc_tok = tok;
}

/// freshly built, unpublished .decl nodes only
/// trees are immutable after publish
pub fn attachDeclPub(node: *CstNode, pub_tok: Token) void {
    std.debug.assert(node.kind == .decl);
    node.kind.decl.pub_tok = pub_tok;
    node.kind.decl.pub_ = true;
}

/// alloc a synthesized ident node (pipe temps, qq placeholders, etc.)
pub fn allocIdent(alloc: std.mem.Allocator, span: Span, name: []const u8) std.mem.Allocator.Error!*CstNode {
    return allocNode(alloc, span, .{ .ident = .{ .tok = syntheticToken(name, span) } });
}

/// skip `paren` wrappers; returns the innermost non-paren node
/// , empty parens `()` yield null
pub fn unwrapParen(node: *const CstNode) ?*const CstNode {
    var cur: *const CstNode = node;
    while (cur.kind == .paren) {
        if (cur.kind.paren.expr) |e| {
            cur = e;
        } else return null;
    }
    return cur;
}

/// mutable variant of unwrapParen
pub fn unwrapParenMut(node: *CstNode) ?*CstNode {
    var cur: *CstNode = node;
    while (cur.kind == .paren) {
        if (cur.kind.paren.expr) |e| {
            cur = e;
        } else return null;
    }
    return cur;
}

/// stmts of a block-like node (block/do_block/root), null otherwise
/// , root unwraps to its stmts; do_block unwraps to its stmts
pub fn blockStmts(node: *const CstNode) ?[]*CstNode {
    // const-cast: callers only read; mutable path uses blockStmtsMut
    const m: *CstNode = @constCast(node);
    return blockStmtsMut(m);
}

/// mutable variant of blockStmts
pub fn blockStmtsMut(node: *CstNode) ?[]*CstNode {
    switch (node.kind) {
        .block => |b| return b.stmts,
        .do_block => |d| return d.stmts,
        .root => |r| return r.stmts,
        else => return null,
    }
}

/// true when the tree contains a `_` ident placeholder (pipe lexical form)
pub fn hasUnderscore(node: *const CstNode) bool {
    var visitor = UnderscoreVisitor{};
    visitor.visit(node);
    return visitor.found;
}

const UnderscoreVisitor = struct {
    found: bool = false,

    pub fn visit(self: *UnderscoreVisitor, node: *const CstNode) void {
        if (self.found) return;
        switch (node.kind) {
            .ident => |i| {
                if (std.mem.eql(u8, i.tok.text, "_")) self.found = true;
            },
            .interpolated => |t| {
                for (t.parts) |part| {
                    if (self.found) return;
                    if (part == .interp) self.visit(part.interp.value);
                }
            },
            else => walkCst(UnderscoreVisitor, self, node),
        }
    }
};

/// read-only recursive walk over child `*CstNode`s (not types/tokens)
/// , visitor must have `visit(*const CstNode)`; optional
/// , `found: bool` field enables early exit like the ast version
pub fn walkCst(comptime Visitor: type, visitor: *Visitor, node: *const CstNode) void {
    if (@hasField(Visitor, "found") and visitor.found) return;
    switch (node.kind) {
        .number, .string, .atom, .ident, .err, .yield => {},
        .interpolated => |t| {
            for (t.parts) |part| {
                if (@hasField(Visitor, "found") and visitor.found) return;
                if (part == .interp) visitor.visit(part.interp.value);
            }
        },
        .unary => |u| visitor.visit(u.expr),
        .binary => |b| {
            visitor.visit(b.left);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(b.right);
        },
        .logical => |l| {
            visitor.visit(l.left);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(l.right);
        },
        .compound => |c| {
            visitor.visit(c.target);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(c.value);
        },
        .assign => |a| {
            visitor.visit(a.target);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(a.value);
        },
        .field => |f| visitor.visit(f.object),
        .dotted_index => |d| visitor.visit(d.object),
        .method_call => |m| {
            visitor.visit(m.object);
            for (m.args) |a| {
                if (@hasField(Visitor, "found") and visitor.found) return;
                visitor.visit(a);
            }
        },
        .index => |ix| {
            visitor.visit(ix.object);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(ix.key);
        },
        .generic_call => |g| {
            visitor.visit(g.receiver);
            for (g.args) |a| {
                if (@hasField(Visitor, "found") and visitor.found) return;
                visitor.visit(a);
            }
        },
        .call => |c| {
            visitor.visit(c.callee);
            for (c.args) |a| {
                if (@hasField(Visitor, "found") and visitor.found) return;
                visitor.visit(a);
            }
        },
        .bare_call => |b| {
            visitor.visit(b.callee);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(b.arg);
        },
        .range => |r| {
            visitor.visit(r.start);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(r.mid);
            if (@hasField(Visitor, "found") and visitor.found) return;
            if (r.end) |e| visitor.visit(e);
        },
        .for_range => |r| {
            if (r.start) |s| {
                visitor.visit(s);
                if (@hasField(Visitor, "found") and visitor.found) return;
            }
            if (r.mid) |m| {
                visitor.visit(m);
                if (@hasField(Visitor, "found") and visitor.found) return;
            }
            if (r.end) |e| visitor.visit(e);
        },
        .slice => |s| {
            if (s.start) |n| {
                visitor.visit(n);
                if (@hasField(Visitor, "found") and visitor.found) return;
            }
            if (s.mid) |n| {
                visitor.visit(n);
                if (@hasField(Visitor, "found") and visitor.found) return;
            }
            if (s.end) |n| visitor.visit(n);
            for (s.dropped) |n| {
                if (@hasField(Visitor, "found") and visitor.found) return;
                visitor.visit(n);
            }
        },
        .pipe => |p| {
            visitor.visit(p.left);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(p.right);
        },
        .try_expr => |t| visitor.visit(t.expr),
        .if_expr => |c| {
            visitor.visit(c.cond);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(c.then);
            if (@hasField(Visitor, "found") and visitor.found) return;
            if (c.else_) |e| visitor.visit(e);
        },
        .match => |m| {
            if (m.subject) |s| {
                visitor.visit(s);
                if (@hasField(Visitor, "found") and visitor.found) return;
            }
            for (m.arms) |arm| {
                for (arm.matchers) |mc| {
                    if (@hasField(Visitor, "found") and visitor.found) return;
                    if (mc == .expr) visitor.visit(mc.expr);
                }
                if (@hasField(Visitor, "found") and visitor.found) return;
                if (arm.guard) |g| {
                    visitor.visit(g);
                    if (@hasField(Visitor, "found") and visitor.found) return;
                }
                visitor.visit(arm.then);
                if (@hasField(Visitor, "found") and visitor.found) return;
            }
        },
        .ascribed => |a| visitor.visit(a.expr),
        .table => |t| {
            for (t.entries) |entry| {
                if (@hasField(Visitor, "found") and visitor.found) return;
                switch (entry) {
                    .computed => |cc| {
                        visitor.visit(cc.key);
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        visitor.visit(cc.value);
                    },
                    .keyed => |k| {
                        visitor.visit(k.key);
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        visitor.visit(k.value);
                    },
                    .bare => |b| visitor.visit(b.value),
                }
            }
        },
        .paren => |p| if (p.expr) |e| visitor.visit(e),
        .block => |b| for (b.stmts) |s| {
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(s);
        },
        .do_block => |d| for (d.stmts) |s| {
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(s);
        },
        .root => |r| for (r.stmts) |s| {
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(s);
        },
        .fn_def => |f| {
            if (f.return_type) |_| {} // types walked separately
            visitor.visit(f.body);
        },
        .fn_method => |f| visitor.visit(f.body),
        .binding => |b| {
            visitor.visit(b.target);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(b.value);
        },
        .decl => |d| visitor.visit(d.inner),
        .import => {},
        .test_block => |t| visitor.visit(t.body),
        .test_suite => |t| visitor.visit(t.body),
        .type_alias => {},
        .for_loop => |f| {
            visitor.visit(f.iter);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(f.body);
        },
        .while_loop => |w| {
            visitor.visit(w.pred);
            if (@hasField(Visitor, "found") and visitor.found) return;
            visitor.visit(w.body);
        },
        .loop_expr => |l| visitor.visit(l.body),
        .break_expr => |b| if (b.value) |v| visitor.visit(v),
        .continue_expr => {},
        .return_expr => |r| if (r.value) |v| visitor.visit(v),
        .comp_block => |c| visitor.visit(c.expr),
    }
}

/// walk a slice of nodes through a Transform (internal to walkCstExpr)
fn walkCstSliceWith(
    alloc: std.mem.Allocator,
    items: []const *CstNode,
    comptime Transform: type,
    ctx: Transform,
) ![]*CstNode {
    var out = try std.ArrayList(*CstNode).initCapacity(alloc, items.len);
    for (items) |item| try out.append(alloc, try ctx.walk(alloc, @constCast(item), ctx));
    return out.toOwnedSlice(alloc);
}

/// transforming walker over `*CstNode`, preserving all tokens
/// , Transform must have `walk(alloc, *CstNode, ctx) !*CstNode`
/// , leaves and token-only nodes (`import`, `type_alias`) are aliased
/// , doc/attr-carrying kinds (decl/fn_def/fn_method/binding/assign) keep them
pub fn walkCstExpr(
    alloc: std.mem.Allocator,
    node: *CstNode,
    comptime Transform: type,
    ctx: Transform,
) !*CstNode {
    switch (node.kind) {
        .number, .string, .atom, .ident, .err, .yield, .import, .type_alias => return node,
        .unary => |u| return allocNode(alloc, node.span, .{ .unary = .{
            .op_tok = u.op_tok,
            .op = u.op,
            .expr = try ctx.walk(alloc, u.expr, ctx),
        } }),
        .binary => |b| return allocNode(alloc, node.span, .{ .binary = .{
            .left = try ctx.walk(alloc, b.left, ctx),
            .op_tok = b.op_tok,
            .op = b.op,
            .right = try ctx.walk(alloc, b.right, ctx),
        } }),
        .logical => |l| return allocNode(alloc, node.span, .{ .logical = .{
            .left = try ctx.walk(alloc, l.left, ctx),
            .op_tok = l.op_tok,
            .op = l.op,
            .right = try ctx.walk(alloc, l.right, ctx),
        } }),
        .compound => |c| return allocNode(alloc, node.span, .{ .compound = .{
            .target = try ctx.walk(alloc, c.target, ctx),
            .op_tok = c.op_tok,
            .op = c.op,
            .value = try ctx.walk(alloc, c.value, ctx),
        } }),
        .assign => |a| {
            const out = try allocNode(alloc, node.span, .{ .assign = .{
                .target = try ctx.walk(alloc, a.target, ctx),
                .eq_tok = a.eq_tok,
                .value = try ctx.walk(alloc, a.value, ctx),
            } });
            // doc/attr-carrying kinds preserve them (see decl arm)
            if (node.doc_tok) |dt| attachDoc(out, dt);
            out.attrs = node.attrs;
            return out;
        },
        .field => |f| return allocNode(alloc, node.span, .{ .field = .{
            .object = try ctx.walk(alloc, f.object, ctx),
            .dot_tok = f.dot_tok,
            .name_tok = f.name_tok,
        } }),
        .dotted_index => |d| return allocNode(alloc, node.span, .{ .dotted_index = .{
            .object = try ctx.walk(alloc, d.object, ctx),
            .dot_tok = d.dot_tok,
            .num_tok = d.num_tok,
            .value = d.value,
        } }),
        .method_call => |m| return allocNode(alloc, node.span, .{ .method_call = .{
            .object = try ctx.walk(alloc, m.object, ctx),
            .atom_tok = m.atom_tok,
            .lparen_tok = m.lparen_tok,
            .args = try walkCstSliceWith(alloc, m.args, Transform, ctx),
            .commas = m.commas,
            .rparen_tok = m.rparen_tok,
        } }),
        .index => |ix| return allocNode(alloc, node.span, .{ .index = .{
            .object = try ctx.walk(alloc, ix.object, ctx),
            .lbracket_tok = ix.lbracket_tok,
            .key = try ctx.walk(alloc, ix.key, ctx),
            .rbracket_tok = ix.rbracket_tok,
        } }),
        .generic_call => |g| return allocNode(alloc, node.span, .{ .generic_call = .{
            .receiver = try ctx.walk(alloc, g.receiver, ctx),
            .lt_tok = g.lt_tok,
            .type_args = g.type_args,
            .commas = g.commas,
            .gt_tok = g.gt_tok,
            .lparen_tok = g.lparen_tok,
            .args = try walkCstSliceWith(alloc, g.args, Transform, ctx),
            .arg_commas = g.arg_commas,
            .rparen_tok = g.rparen_tok,
        } }),
        .call => |c| return allocNode(alloc, node.span, .{ .call = .{
            .callee = try ctx.walk(alloc, c.callee, ctx),
            .lparen_tok = c.lparen_tok,
            .args = try walkCstSliceWith(alloc, c.args, Transform, ctx),
            .commas = c.commas,
            .rparen_tok = c.rparen_tok,
        } }),
        .bare_call => |b| return allocNode(alloc, node.span, .{ .bare_call = .{
            .callee = try ctx.walk(alloc, b.callee, ctx),
            .arg = try ctx.walk(alloc, b.arg, ctx),
        } }),
        .range => |r| return allocNode(alloc, node.span, .{ .range = .{
            .start = try ctx.walk(alloc, r.start, ctx),
            .dot1_tok = r.dot1_tok,
            .mid = try ctx.walk(alloc, r.mid, ctx),
            .dot2_tok = r.dot2_tok,
            .end = if (r.end) |e| try ctx.walk(alloc, e, ctx) else null,
        } }),
        .for_range => |r| return allocNode(alloc, node.span, .{ .for_range = .{
            .start = if (r.start) |s| try ctx.walk(alloc, s, ctx) else null,
            .dot1_tok = r.dot1_tok,
            .mid = if (r.mid) |m| try ctx.walk(alloc, m, ctx) else null,
            .dot2_tok = r.dot2_tok,
            .end = if (r.end) |e| try ctx.walk(alloc, e, ctx) else null,
        } }),
        .slice => |s| return allocNode(alloc, node.span, .{ .slice = .{
            .lbracket_tok = s.lbracket_tok,
            .start = if (s.start) |n| try ctx.walk(alloc, n, ctx) else null,
            .dots = s.dots,
            .mid = if (s.mid) |n| try ctx.walk(alloc, n, ctx) else null,
            .end = if (s.end) |n| try ctx.walk(alloc, n, ctx) else null,
            .rbracket_tok = s.rbracket_tok,
            .dropped = try walkCstSliceWith(alloc, s.dropped, Transform, ctx),
        } }),
        .pipe => |p| return allocNode(alloc, node.span, .{ .pipe = .{
            .left = try ctx.walk(alloc, p.left, ctx),
            .pipe_tok = p.pipe_tok,
            .right = try ctx.walk(alloc, p.right, ctx),
        } }),
        .try_expr => |t| return allocNode(alloc, node.span, .{ .try_expr = .{
            .expr = try ctx.walk(alloc, t.expr, ctx),
            .qmark_tok = t.qmark_tok,
        } }),
        .if_expr => |c| return allocNode(alloc, node.span, .{ .if_expr = .{
            .kw_tok = c.kw_tok,
            .unless = c.unless,
            .cond = try ctx.walk(alloc, c.cond, ctx),
            .then = try ctx.walk(alloc, c.then, ctx),
            .else_tok = c.else_tok,
            .else_ = if (c.else_) |e| try ctx.walk(alloc, e, ctx) else null,
        } }),
        .match => |m| {
            const arms = try alloc.alloc(CstArm, m.arms.len);
            for (m.arms, arms) |arm, *dst| {
                const matchers = try alloc.alloc(CstMatcher, arm.matchers.len);
                for (arm.matchers, matchers) |mc, *mdst| mdst.* = switch (mc) {
                    .wildcard => mc,
                    .expr => |e| .{ .expr = try ctx.walk(alloc, e, ctx) },
                };
                dst.* = .{
                    .matchers = matchers,
                    .commas = arm.commas,
                    .when_tok = arm.when_tok,
                    .guard = if (arm.guard) |g| try ctx.walk(alloc, g, ctx) else null,
                    .arrow_tok = arm.arrow_tok,
                    .then = try ctx.walk(alloc, arm.then, ctx),
                };
            }
            return allocNode(alloc, node.span, .{ .match = .{
                .kw_tok = m.kw_tok,
                .subject = if (m.subject) |s| try ctx.walk(alloc, s, ctx) else null,
                .bars = m.bars,
                .arms = arms,
            } });
        },
        .ascribed => |a| return allocNode(alloc, node.span, .{ .ascribed = .{
            .expr = try ctx.walk(alloc, a.expr, ctx),
            .colon_tok = a.colon_tok,
            .type = a.type,
        } }),
        .table => |t| {
            const entries = try alloc.alloc(CstEntry, t.entries.len);
            for (t.entries, entries) |entry, *dst| {
                dst.* = switch (entry) {
                    .computed => |cc| .{ .computed = .{
                        .lbracket_tok = cc.lbracket_tok,
                        .key = try ctx.walk(alloc, cc.key, ctx),
                        .rbracket_tok = cc.rbracket_tok,
                        .eq_tok = cc.eq_tok,
                        .value = try ctx.walk(alloc, cc.value, ctx),
                    } },
                    .keyed => |k| .{ .keyed = .{
                        .key = try ctx.walk(alloc, k.key, ctx),
                        .eq_tok = k.eq_tok,
                        .value = try ctx.walk(alloc, k.value, ctx),
                    } },
                    .bare => |b| .{ .bare = .{
                        .value = try ctx.walk(alloc, b.value, ctx),
                    } },
                };
            }
            return allocNode(alloc, node.span, .{ .table = .{
                .lbrace_tok = t.lbrace_tok,
                .entries = entries,
                .commas = t.commas,
                .rbrace_tok = t.rbrace_tok,
            } });
        },
        .paren => |p| return allocNode(alloc, node.span, .{ .paren = .{
            .lparen_tok = p.lparen_tok,
            .expr = if (p.expr) |e| try ctx.walk(alloc, e, ctx) else null,
            .rparen_tok = p.rparen_tok,
        } }),
        .block => |b| return allocNode(alloc, node.span, .{ .block = .{
            .stmts = try walkCstSliceWith(alloc, b.stmts, Transform, ctx),
            .semis = b.semis,
        } }),
        .do_block => |d| return allocNode(alloc, node.span, .{ .do_block = .{
            .do_tok = d.do_tok,
            .slash_tok = d.slash_tok,
            .label_tok = d.label_tok,
            .stmts = try walkCstSliceWith(alloc, d.stmts, Transform, ctx),
            .semis = d.semis,
            .end_tok = d.end_tok,
        } }),
        .root => |r| return allocNode(alloc, node.span, .{ .root = .{
            .stmts = try walkCstSliceWith(alloc, r.stmts, Transform, ctx),
            .semis = r.semis,
            .eof_tok = r.eof_tok,
            .trivia = r.trivia,
        } }),
        .fn_def => |f| {
            const params = try alloc.alloc(CstParam, f.params.len);
            for (f.params, params) |p, *dst| {
                dst.* = p;
                if (p.default) |d| dst.default = try ctx.walk(alloc, d, ctx);
            }
            const out = try allocNode(alloc, node.span, .{ .fn_def = .{
                .fn_tok = f.fn_tok,
                .head = f.head,
                .kind = f.kind,
                .lt_tok = f.lt_tok,
                .type_params = f.type_params,
                .tp_commas = f.tp_commas,
                .gt_tok = f.gt_tok,
                .lparen_tok = f.lparen_tok,
                .params = params,
                .commas = f.commas,
                .rparen_tok = f.rparen_tok,
                .arrow_tok = f.arrow_tok,
                .return_type = f.return_type,
                .body = try ctx.walk(alloc, f.body, ctx),
            } });
            // doc/attr-carrying kinds preserve them (see decl arm)
            if (node.doc_tok) |dt| attachDoc(out, dt);
            out.attrs = node.attrs;
            return out;
        },
        .fn_method => |f| {
            const params = try alloc.alloc(CstParam, f.params.len);
            for (f.params, params) |p, *dst| {
                dst.* = p;
                if (p.default) |d| dst.default = try ctx.walk(alloc, d, ctx);
            }
            const out = try allocNode(alloc, node.span, .{ .fn_method = .{
                .fn_tok = f.fn_tok,
                .head = f.head,
                .lt_tok = f.lt_tok,
                .type_params = f.type_params,
                .tp_commas = f.tp_commas,
                .gt_tok = f.gt_tok,
                .lparen_tok = f.lparen_tok,
                .params = params,
                .commas = f.commas,
                .rparen_tok = f.rparen_tok,
                .arrow_tok = f.arrow_tok,
                .return_type = f.return_type,
                .body = try ctx.walk(alloc, f.body, ctx),
            } });
            // doc/attr-carrying kinds preserve them (see decl arm)
            if (node.doc_tok) |dt| attachDoc(out, dt);
            out.attrs = node.attrs;
            return out;
        },
        .binding => |b| {
            const out = try allocNode(alloc, node.span, .{ .binding = .{
                .kind_tok = b.kind_tok,
                .kind = b.kind,
                .target = try ctx.walk(alloc, b.target, ctx),
                .colon_tok = b.colon_tok,
                .type = b.type,
                .eq_tok = b.eq_tok,
                .value = try ctx.walk(alloc, b.value, ctx),
            } });
            // doc/attr-carrying kinds preserve them (see decl arm)
            if (node.doc_tok) |dt| attachDoc(out, dt);
            out.attrs = node.attrs;
            return out;
        },
        .decl => |d| {
            const inner = try ctx.walk(alloc, d.inner, ctx);
            const out = try allocNode(alloc, node.span, .{ .decl = .{
                .pub_tok = d.pub_tok,
                .kind = d.kind,
                .inner = inner,
                .pub_ = d.pub_,
            } });
            // construction time, never on shared nodes
            if (node.doc_tok) |dt| attachDoc(out, dt);
            out.attrs = node.attrs;
            return out;
        },
        .test_block => |t| return allocNode(alloc, node.span, .{ .test_block = .{
            .kw_tok = t.kw_tok,
            .slash_tok = t.slash_tok,
            .skip_tok = t.skip_tok,
            .name = t.name,
            .body = try ctx.walk(alloc, t.body, ctx),
        } }),
        .test_suite => |t| return allocNode(alloc, node.span, .{ .test_suite = .{
            .kw_tok = t.kw_tok,
            .name = t.name,
            .body = try ctx.walk(alloc, t.body, ctx),
        } }),
        .for_loop => |f| {
            return allocNode(alloc, node.span, .{ .for_loop = .{
                .for_tok = f.for_tok,
                .slash_tok = f.slash_tok,
                .label_tok = f.label_tok,
                .params = f.params,
                .commas = f.commas,
                .in_tok = f.in_tok,
                .iter = try ctx.walk(alloc, f.iter, ctx),
                .body = try ctx.walk(alloc, f.body, ctx),
            } });
        },
        .while_loop => |w| return allocNode(alloc, node.span, .{ .while_loop = .{
            .kw_tok = w.kw_tok,
            .slash_tok = w.slash_tok,
            .label_tok = w.label_tok,
            .pred = try ctx.walk(alloc, w.pred, ctx),
            .body = try ctx.walk(alloc, w.body, ctx),
        } }),
        .loop_expr => |l| return allocNode(alloc, node.span, .{ .loop_expr = .{
            .kw_tok = l.kw_tok,
            .slash_tok = l.slash_tok,
            .label_tok = l.label_tok,
            .body = try ctx.walk(alloc, l.body, ctx),
        } }),
        .break_expr => |b| return allocNode(alloc, node.span, .{ .break_expr = .{
            .kw_tok = b.kw_tok,
            .slash_tok = b.slash_tok,
            .label_tok = b.label_tok,
            .value = if (b.value) |v| try ctx.walk(alloc, v, ctx) else null,
        } }),
        .continue_expr => return node,
        .return_expr => |r| return allocNode(alloc, node.span, .{ .return_expr = .{
            .kw_tok = r.kw_tok,
            .value = if (r.value) |v| try ctx.walk(alloc, v, ctx) else null,
        } }),
        .comp_block => |c| return allocNode(alloc, node.span, .{ .comp_block = .{
            .kw_tok = c.kw_tok,
            .expr = try ctx.walk(alloc, c.expr, ctx),
        } }),
        .interpolated => |t| {
            const parts = try alloc.alloc(CstInterpPart, t.parts.len);
            for (t.parts, parts) |part, *dst| {
                dst.* = switch (part) {
                    .literal => part,
                    .interp => |in| .{ .interp = .{
                        .open_tok = in.open_tok,
                        .value = try ctx.walk(alloc, in.value, ctx),
                        .mode = in.mode,
                        .mode_tok = in.mode_tok,
                        .close_tok = in.close_tok,
                    } },
                };
            }
            return allocNode(alloc, node.span, .{ .interpolated = .{
                .start_tok = t.start_tok,
                .parts = parts,
                .end_tok = t.end_tok,
                .multiline = t.multiline,
            } });
        },
    }
}

/// desugar `left |> right` into call/block nodes (cst-only)
/// , mirrors the old ast desugar: `_` placeholder wins (lexical block),
/// , ident/fn/call plug left as first arg, binary plugs leftmost
/// , like the old bottom-up lowering, a left-rooted pipe desugars first
/// , so nested pipes reveal block shape; block-shaped lefts hoist into a
/// , temp (never compile decl-bearing blocks inline as call args)
pub fn desugarPipe(alloc: std.mem.Allocator, left: *CstNode, right: *CstNode, span: Span) std.mem.Allocator.Error!*CstNode {
    const r = unwrapParen(right) orelse return right;
    if (hasUnderscore(right)) return pipeLexicalNode(alloc, left, right, span);
    // bottom-up: a left-rooted pipe desugars before the outer plug
    const dl = blk: {
        const lu = unwrapParen(left) orelse break :blk left;
        if (lu.kind == .pipe) break :blk try desugarPipe(alloc, lu.kind.pipe.left, lu.kind.pipe.right, lu.span);
        break :blk left;
    };
    const dl_blocky = blk: {
        const du = unwrapParen(dl) orelse break :blk false;
        break :blk du.kind == .block or du.kind == .do_block;
    };
    switch (r.kind) {
        .ident, .fn_def => {
            if (dl_blocky) {
                const tmp = try pipeTempNodes(alloc, dl);
                const args = try alloc.alloc(*CstNode, 1);
                args[0] = tmp.ref;
                return pipeTempBlock(alloc, span, tmp.bind, try allocNode(alloc, span, .{ .call = .{
                    .callee = @constCast(r),
                    .lparen_tok = syntheticToken("(", span),
                    .args = args,
                    .commas = &.{},
                    .rparen_tok = syntheticToken(")", span),
                } }));
            }
            const args = try alloc.alloc(*CstNode, 1);
            args[0] = dl;
            return allocNode(alloc, span, .{ .call = .{
                .callee = @constCast(r),
                .lparen_tok = syntheticToken("(", span),
                .args = args,
                .commas = &.{},
                .rparen_tok = syntheticToken(")", span),
            } });
        },
        .call => |c| {
            if (dl_blocky) {
                const tmp = try pipeTempNodes(alloc, dl);
                const args = try alloc.alloc(*CstNode, c.args.len + 1);
                args[0] = tmp.ref;
                @memcpy(args[1..], c.args);
                return pipeTempBlock(alloc, span, tmp.bind, try allocNode(alloc, span, .{ .call = .{
                    .callee = c.callee,
                    .lparen_tok = c.lparen_tok,
                    .args = args,
                    .commas = c.commas,
                    .rparen_tok = c.rparen_tok,
                } }));
            }
            const args = try alloc.alloc(*CstNode, c.args.len + 1);
            args[0] = dl;
            @memcpy(args[1..], c.args);
            return allocNode(alloc, span, .{ .call = .{
                .callee = c.callee,
                .lparen_tok = c.lparen_tok,
                .args = args,
                .commas = c.commas,
                .rparen_tok = c.rparen_tok,
            } });
        },
        .bare_call => |b| {
            if (dl_blocky) {
                const tmp = try pipeTempNodes(alloc, dl);
                const args = try alloc.alloc(*CstNode, 2);
                args[0] = tmp.ref;
                args[1] = b.arg;
                return pipeTempBlock(alloc, span, tmp.bind, try allocNode(alloc, span, .{ .call = .{
                    .callee = b.callee,
                    .lparen_tok = syntheticToken("(", span),
                    .args = args,
                    .commas = &.{},
                    .rparen_tok = syntheticToken(")", span),
                } }));
            }
            const args = try alloc.alloc(*CstNode, 2);
            args[0] = dl;
            args[1] = b.arg;
            return allocNode(alloc, span, .{ .call = .{
                .callee = b.callee,
                .lparen_tok = syntheticToken("(", span),
                .args = args,
                .commas = &.{},
                .rparen_tok = syntheticToken(")", span),
            } });
        },
        .method_call => |m| {
            if (dl_blocky) {
                const tmp = try pipeTempNodes(alloc, dl);
                const args = try alloc.alloc(*CstNode, m.args.len + 1);
                args[0] = tmp.ref;
                @memcpy(args[1..], m.args);
                return pipeTempBlock(alloc, span, tmp.bind, try allocNode(alloc, span, .{ .method_call = .{
                    .object = m.object,
                    .atom_tok = m.atom_tok,
                    .lparen_tok = m.lparen_tok,
                    .args = args,
                    .commas = m.commas,
                    .rparen_tok = m.rparen_tok,
                } }));
            }
            const args = try alloc.alloc(*CstNode, m.args.len + 1);
            args[0] = dl;
            @memcpy(args[1..], m.args);
            return allocNode(alloc, span, .{ .method_call = .{
                .object = m.object,
                .atom_tok = m.atom_tok,
                .lparen_tok = m.lparen_tok,
                .args = args,
                .commas = m.commas,
                .rparen_tok = m.rparen_tok,
            } });
        },
        .generic_call => |g| {
            if (dl_blocky) {
                const tmp = try pipeTempNodes(alloc, dl);
                const args = try alloc.alloc(*CstNode, g.args.len + 1);
                args[0] = tmp.ref;
                @memcpy(args[1..], g.args);
                return pipeTempBlock(alloc, span, tmp.bind, try allocNode(alloc, span, .{ .generic_call = .{
                    .receiver = g.receiver,
                    .lt_tok = g.lt_tok,
                    .type_args = g.type_args,
                    .commas = g.commas,
                    .gt_tok = g.gt_tok,
                    .lparen_tok = g.lparen_tok,
                    .args = args,
                    .arg_commas = g.arg_commas,
                    .rparen_tok = g.rparen_tok,
                } }));
            }
            const args = try alloc.alloc(*CstNode, g.args.len + 1);
            args[0] = dl;
            @memcpy(args[1..], g.args);
            return allocNode(alloc, span, .{ .generic_call = .{
                .receiver = g.receiver,
                .lt_tok = g.lt_tok,
                .type_args = g.type_args,
                .commas = g.commas,
                .gt_tok = g.gt_tok,
                .lparen_tok = g.lparen_tok,
                .args = args,
                .arg_commas = g.arg_commas,
                .rparen_tok = g.rparen_tok,
            } });
        },
        // pipe binds tighter than infix; plug into leftmost operand
        .binary => |b| {
            const plugged = try desugarPipe(alloc, dl, b.left, span);
            return allocNode(alloc, span, .{ .binary = .{
                .left = plugged,
                .op_tok = b.op_tok,
                .op = b.op,
                .right = b.right,
            } });
        },
        else => return pipeLexicalNode(alloc, dl, right, span),
    }
}

const PipeTemp = struct { bind: *CstNode, ref: *CstNode };

/// `const _ = left` (decl-wrapped) plus a `_` reference to it
fn pipeTempNodes(alloc: std.mem.Allocator, left: *CstNode) std.mem.Allocator.Error!PipeTemp {
    const target = try allocIdent(alloc, left.span, "_");
    const bind = try allocNode(alloc, left.span, .{ .binding = .{
        .kind_tok = syntheticToken("const", left.span),
        .kind = .@"const",
        .target = target,
        .colon_tok = null,
        .type = null,
        .eq_tok = syntheticToken("=", left.span),
        .value = left,
    } });
    const decl = try allocNode(alloc, left.span, .{ .decl = .{
        .pub_tok = null,
        .kind = .@"const",
        .inner = bind,
        .pub_ = false,
    } });
    return .{ .bind = decl, .ref = try allocIdent(alloc, left.span, "_") };
}

fn pipeTempBlock(alloc: std.mem.Allocator, span: Span, bind: *CstNode, call: *CstNode) std.mem.Allocator.Error!*CstNode {
    return allocNode(alloc, span, .{ .block = .{
        .stmts = try alloc.dupe(*CstNode, &[_]*CstNode{ bind, call }),
        .semis = &.{},
    } });
}

fn pipeLexicalNode(alloc: std.mem.Allocator, left: *CstNode, right: *CstNode, span: Span) std.mem.Allocator.Error!*CstNode {
    const tmp = try pipeTempNodes(alloc, left);
    return pipeTempBlock(alloc, span, tmp.bind, right);
}

/// +/-inf for open-ended ranges based on step sign (cst-only, no ast nodes)
/// , mirrors sentinelForStep but reads cst number/unary directly
pub fn sentinelForCstStep(step: *const CstNode) f64 {
    const s = unwrapParen(step) orelse return std.math.inf(f64);
    switch (s.kind) {
        .number => |n| {
            if (n.value < 0) return -std.math.inf(f64);
            return std.math.inf(f64);
        },
        .unary => |u| if (u.op == .negate) {
            const inner = unwrapParen(u.expr) orelse return std.math.inf(f64);
            if (inner.kind == .number and inner.kind.number.value > 0)
                return -std.math.inf(f64);
            return std.math.inf(f64);
        } else return std.math.inf(f64),
        else => return std.math.inf(f64),
    }
}

// -- [cst type ownership] ----------------------------------------------------
//
// specs and other permanent tables own their type trees: clone dupes every
// token text, free releases them. paired like ast cloneTypeExpr/freeTypeExpr

fn cloneToken(alloc: std.mem.Allocator, tok: Token) std.mem.Allocator.Error!Token {
    var out = tok;
    out.text = try alloc.dupe(u8, tok.text);
    return out;
}

fn cloneTokenOpt(alloc: std.mem.Allocator, tok: ?Token) std.mem.Allocator.Error!?Token {
    if (tok) |t| return try cloneToken(alloc, t);
    return null;
}

fn cloneTokens(alloc: std.mem.Allocator, toks: []Token) std.mem.Allocator.Error![]Token {
    const out = try alloc.alloc(Token, toks.len);
    for (toks, out) |t, *dst| dst.* = try cloneToken(alloc, t);
    return out;
}

/// deep-copy a CstType, duping every token text; paired with freeCstType
pub fn cloneCstType(alloc: std.mem.Allocator, t: *const CstType) std.mem.Allocator.Error!*CstType {
    const kind: CstTypeKind = switch (t.kind) {
        .named => |n| .{ .named = .{ .tok = try cloneToken(alloc, n.tok) } },
        .atom => |a| .{ .atom = .{ .tok = try cloneToken(alloc, a.tok) } },
        .union_of => |u| blk: {
            const rest = try alloc.alloc(*CstType, u.rest.len);
            for (u.rest, rest) |r, *dst| dst.* = try cloneCstType(alloc, r);
            break :blk .{ .union_of = .{
                .first = try cloneCstType(alloc, u.first),
                .bars = try cloneTokens(alloc, u.bars),
                .rest = rest,
            } };
        },
        .optional => |o| .{ .optional = .{ .inner = try cloneCstType(alloc, o.inner) } },
        .parameterized => |p| blk: {
            const args = try alloc.alloc(*CstType, p.args.len);
            for (p.args, args) |a, *dst| dst.* = try cloneCstType(alloc, a);
            break :blk .{ .parameterized = .{
                .name_tok = try cloneToken(alloc, p.name_tok),
                .lt_tok = try cloneToken(alloc, p.lt_tok),
                .args = args,
                .commas = try cloneTokens(alloc, p.commas),
                .gt_tok = try cloneToken(alloc, p.gt_tok),
            } };
        },
        .qualified => |q| .{ .qualified = .{
            .mod_tok = try cloneToken(alloc, q.mod_tok),
            .dot_tok = try cloneToken(alloc, q.dot_tok),
            .name_tok = try cloneToken(alloc, q.name_tok),
        } },
        .qualified_optional => |q| .{ .qualified_optional = .{
            .mod_tok = try cloneToken(alloc, q.mod_tok),
            .dot_tok = try cloneToken(alloc, q.dot_tok),
            .name_tok = try cloneToken(alloc, q.name_tok),
        } },
        .function => |f| blk: {
            const params = try alloc.alloc(CstTypeParam, f.params.len);
            for (f.params, params) |p, *dst| {
                dst.* = .{
                    .qmark_tok = try cloneTokenOpt(alloc, p.qmark_tok),
                    .name_tok = try cloneToken(alloc, p.name_tok),
                    .colon_tok = try cloneTokenOpt(alloc, p.colon_tok),
                    .type = if (p.type) |pt| try cloneCstType(alloc, pt) else null,
                    .dots = try cloneTokens(alloc, p.dots),
                };
            }
            break :blk .{ .function = .{
                .fn_tok = try cloneToken(alloc, f.fn_tok),
                .lt_tok = try cloneTokenOpt(alloc, f.lt_tok),
                .tps = try cloneTokens(alloc, f.tps),
                .tp_commas = try cloneTokens(alloc, f.tp_commas),
                .gt_tok = try cloneTokenOpt(alloc, f.gt_tok),
                .lparen_tok = try cloneToken(alloc, f.lparen_tok),
                .params = params,
                .commas = try cloneTokens(alloc, f.commas),
                .rparen_tok = try cloneToken(alloc, f.rparen_tok),
                .arrow_tok = try cloneTokenOpt(alloc, f.arrow_tok),
                .ret = if (f.ret) |r| try cloneCstType(alloc, r) else null,
            } };
        },
        .paren => |p| .{ .paren = .{
            .lparen_tok = try cloneToken(alloc, p.lparen_tok),
            .inner = try cloneCstType(alloc, p.inner),
            .rparen_tok = try cloneToken(alloc, p.rparen_tok),
        } },
        .error_union => |e| .{ .error_union = .{
            .bang_tok = try cloneToken(alloc, e.bang_tok),
            .inner = try cloneCstType(alloc, e.inner),
        } },
        .record => |r| blk: {
            const fields = try alloc.alloc(CstRecordField, r.fields.len);
            for (r.fields, fields) |fld, *dst| {
                dst.* = .{
                    .doc_tok = try cloneTokenOpt(alloc, fld.doc_tok),
                    .qmark_tok = try cloneTokenOpt(alloc, fld.qmark_tok),
                    .name_tok = try cloneTokenOpt(alloc, fld.name_tok),
                    .colon_tok = try cloneTokenOpt(alloc, fld.colon_tok),
                    .type = try cloneCstType(alloc, fld.type),
                };
            }
            break :blk .{ .record = .{
                .lbrace_tok = try cloneToken(alloc, r.lbrace_tok),
                .fields = fields,
                .commas = try cloneTokens(alloc, r.commas),
                .rbrace_tok = try cloneToken(alloc, r.rbrace_tok),
            } };
        },
        .slashed => |s| .{ .slashed = .{
            .inner = try cloneCstType(alloc, s.inner),
            .slash_tok = try cloneToken(alloc, s.slash_tok),
            .tag = try cloneCstType(alloc, s.tag),
        } },
    };
    return allocType(alloc, t.span, kind);
}

fn freeTokenText(alloc: std.mem.Allocator, tok: Token) void {
    alloc.free(tok.text);
}

fn freeTokensText(alloc: std.mem.Allocator, toks: []Token) void {
    for (toks) |t| freeTokenText(alloc, t);
    alloc.free(toks);
}

/// free a cloneCstType tree: token texts, slices, nodes
pub fn freeCstType(alloc: std.mem.Allocator, t: *CstType) void {
    switch (t.kind) {
        .named => |n| freeTokenText(alloc, n.tok),
        .atom => |a| freeTokenText(alloc, a.tok),
        .union_of => |u| {
            freeCstType(alloc, u.first);
            freeTokensText(alloc, u.bars);
            for (u.rest) |r| freeCstType(alloc, r);
            alloc.free(u.rest);
        },
        .optional => |o| freeCstType(alloc, o.inner),
        .parameterized => |p| {
            freeTokenText(alloc, p.name_tok);
            freeTokenText(alloc, p.lt_tok);
            for (p.args) |a| freeCstType(alloc, a);
            alloc.free(p.args);
            freeTokensText(alloc, p.commas);
            freeTokenText(alloc, p.gt_tok);
        },
        .qualified => |q| {
            freeTokenText(alloc, q.mod_tok);
            freeTokenText(alloc, q.dot_tok);
            freeTokenText(alloc, q.name_tok);
        },
        .qualified_optional => |q| {
            freeTokenText(alloc, q.mod_tok);
            freeTokenText(alloc, q.dot_tok);
            freeTokenText(alloc, q.name_tok);
        },
        .function => |f| {
            freeTokenText(alloc, f.fn_tok);
            if (f.lt_tok) |tok| freeTokenText(alloc, tok);
            freeTokensText(alloc, f.tps);
            freeTokensText(alloc, f.tp_commas);
            if (f.gt_tok) |tok| freeTokenText(alloc, tok);
            freeTokenText(alloc, f.lparen_tok);
            for (f.params) |p| {
                if (p.qmark_tok) |tok| freeTokenText(alloc, tok);
                freeTokenText(alloc, p.name_tok);
                if (p.colon_tok) |tok| freeTokenText(alloc, tok);
                if (p.type) |pt| freeCstType(alloc, pt);
                freeTokensText(alloc, p.dots);
            }
            alloc.free(f.params);
            freeTokensText(alloc, f.commas);
            freeTokenText(alloc, f.rparen_tok);
            if (f.arrow_tok) |tok| freeTokenText(alloc, tok);
            if (f.ret) |r| freeCstType(alloc, r);
        },
        .paren => |p| {
            freeTokenText(alloc, p.lparen_tok);
            freeCstType(alloc, p.inner);
            freeTokenText(alloc, p.rparen_tok);
        },
        .error_union => |e| {
            freeTokenText(alloc, e.bang_tok);
            freeCstType(alloc, e.inner);
        },
        .record => |r| {
            freeTokenText(alloc, r.lbrace_tok);
            for (r.fields) |fld| {
                if (fld.doc_tok) |tok| freeTokenText(alloc, tok);
                if (fld.qmark_tok) |tok| freeTokenText(alloc, tok);
                if (fld.name_tok) |tok| freeTokenText(alloc, tok);
                if (fld.colon_tok) |tok| freeTokenText(alloc, tok);
                freeCstType(alloc, fld.type);
            }
            alloc.free(r.fields);
            freeTokensText(alloc, r.commas);
            freeTokenText(alloc, r.rbrace_tok);
        },
        .slashed => |s| {
            freeCstType(alloc, s.inner);
            freeTokenText(alloc, s.slash_tok);
            freeCstType(alloc, s.tag);
        },
    }
    alloc.destroy(t);
}

/// render a CstType to the writer (sugar-aware: `T?`, parens dropped,
/// `/tag` dropped like lowering, positional records numeric)
pub fn printCstType(t: *const CstType, writer: *std.Io.Writer) !void {
    switch (t.kind) {
        .named => |n| {
            // `name?` glue: the `?` rides on the token; print as-is
            try writer.writeAll(n.tok.text);
        },
        .atom => |a| {
            const txt = a.tok.text;
            if (txt.len > 0 and txt[0] == ':') try writer.writeAll(txt) else try writer.print(":{s}", .{txt});
        },
        .union_of => |u| {
            try printCstType(u.first, writer);
            for (u.rest) |r| {
                try writer.writeAll(" | ");
                try printCstType(r, writer);
            }
        },
        .optional => |o| {
            // inner is `named` with glued `?`; print stripped + `?`
            switch (o.inner.kind) {
                .named => |n| {
                    const txt = n.tok.text;
                    if (std.mem.endsWith(u8, txt, "?")) try writer.writeAll(txt) else {
                        try writer.writeAll(txt);
                        try writer.writeByte('?');
                    }
                },
                else => {
                    try printCstType(o.inner, writer);
                    try writer.writeByte('?');
                },
            }
        },
        .parameterized => |p| {
            try writer.writeAll(p.name_tok.text);
            try writer.writeByte('<');
            for (p.args, 0..) |a, i| {
                if (i > 0) try writer.writeAll(", ");
                try printCstType(a, writer);
            }
            try writer.writeByte('>');
        },
        .qualified => |q| {
            try writer.writeAll(q.mod_tok.text);
            try writer.writeByte('.');
            try writer.writeAll(q.name_tok.text);
        },
        .qualified_optional => |q| {
            try writer.writeAll(q.mod_tok.text);
            try writer.writeByte('.');
            try writer.writeAll(q.name_tok.text);
        },
        .function => |f| {
            try writer.writeAll("fn");
            if (f.tps.len > 0) {
                try writer.writeByte('<');
                for (f.tps, 0..) |tp, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(tp.text);
                }
                try writer.writeByte('>');
            }
            try writer.writeByte('(');
            for (f.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                if (p.qmark_tok != null) try writer.writeByte('?');
                try writer.writeAll(p.name_tok.text);
                if (p.type) |pt| {
                    try writer.writeAll(": ");
                    try printCstType(pt, writer);
                }
                if (p.dots.len == 2) try writer.writeAll("...");
            }
            try writer.writeByte(')');
            if (f.ret) |r| {
                try writer.writeAll(" -> ");
                try printCstType(r, writer);
            }
        },
        .paren => |p| try printCstType(p.inner, writer),
        .error_union => |e| {
            try writer.writeByte('!');
            try printCstType(e.inner, writer);
        },
        .record => |r| {
            try writer.writeByte('{');
            for (r.fields, 0..) |fld, i| {
                if (i > 0) try writer.writeAll(", ");
                // positional fields print bare, like the old printer
                if (fld.name_tok) |nt| {
                    if (fld.qmark_tok != null) try writer.writeByte('?');
                    try writer.writeAll(nt.text);
                    try writer.writeAll(": ");
                }
                try printCstType(fld.type, writer);
            }
            try writer.writeByte('}');
        },
        .slashed => |s| try printCstType(s.inner, writer),
    }
}

test "trivia attaches to the next token" {
    const alloc = std.testing.allocator;
    const out = try Lexer.lexAll(alloc, "let x = 1 # hi\nlet y = 2");
    defer Lexer.freeLexOutput(alloc, out);
    // second `let` owns the `# hi` comment plus one newline
    var second_let: ?Token = null;
    for (out.tokens) |t| {
        if (t.type == .kw_let and t.start > 0) second_let = t;
    }

    const tok = second_let orelse return error.SkipZigTest;
    try std.testing.expect(tok.nl_before);
    try std.testing.expectEqual(@as(u32, 1), tok.newlines_before);
    try std.testing.expect(!out.hasBlankLine(tok));

    const lead = out.leadingTrivia(tok);
    try std.testing.expectEqual(@as(usize, 1), lead.len);
    try std.testing.expectEqual(TokenType.comment, lead[0].type);
}

test "blank line survives as newline counts" {
    const alloc = std.testing.allocator;
    const out = try Lexer.lexAll(alloc, "1\n\n\n2");
    defer Lexer.freeLexOutput(alloc, out);

    var two: ?Token = null;
    for (out.tokens) |t| {
        if (t.type == .number and t.start > 0) two = t;
    }

    const tok = two orelse return error.SkipZigTest;
    try std.testing.expect(tok.newlines_before >= 2);
    try std.testing.expect(out.hasBlankLine(tok));
}

test "trailing trivia attaches to eof" {
    const alloc = std.testing.allocator;
    const out = try Lexer.lexAll(alloc, "1 # tail");

    defer Lexer.freeLexOutput(alloc, out);
    const eof = out.tokens[out.tokens.len - 1];

    try std.testing.expectEqual(TokenType.eof, eof.type);
    try std.testing.expectEqual(@as(usize, 1), out.leadingTrivia(eof).len);
}

test "hasUnderscore" {
    const pipeline = @import("pipeline.zig");
    var alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer alloc.deinit();
    const arena = alloc.allocator();
    var res = (try pipeline.parse(arena, .{ .text = "_", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "x", .name = "<>" }, .{})).ok;
    try std.testing.expect(!hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "{_, x}", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "call{_, x}", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "{a, b}", .name = "<>" }, .{})).ok;
    try std.testing.expect(!hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "_:meth()", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "_ + 42", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
}
