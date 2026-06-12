const std = @import("std");
const lang = @import("./root.zig");

const ast = lang.ast;
const Node = ast.Node;
const Span = ast.Span;
const pipeline = lang.pipeline;

pub const ExpandError = error{
    UnsupportedMacroPattern,
    UnsupportedMacroTemplate,
    InvalidPipeTarget,
    ParseFailed,
    InvalidIntrospection,
    InvalidMacroName,
} || std.mem.Allocator.Error;

//
// api
//
pub fn expandExpr(allocator: std.mem.Allocator, expr: *Node) ExpandError!*Node {
    var env = MacroEnv.init(allocator);
    defer env.deinit();
    return expandInEnv(allocator, expr, &env);
}

const MacroDef = struct {
    pattern: []const ast.PatternNode,
    template: []const u8,
};

const MacroEnv = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(MacroDef),

    fn init(allocator: std.mem.Allocator) MacroEnv {
        return .{ .allocator = allocator, .map = std.StringHashMap(MacroDef).init(allocator) };
    }

    fn deinit(self: *MacroEnv) void {
        self.map.deinit();
    }

    fn clone(self: *const MacroEnv) !MacroEnv {
        var next = MacroEnv.init(self.allocator);
        var it = self.map.iterator();
        while (it.next()) |entry| try next.map.put(entry.key_ptr.*, entry.value_ptr.*);
        return next;
    }
};

const SingleCapture = struct {
    name: []const u8,
    expr: *Node,
};

const GroupCapture = struct {
    name: []const u8,
    item_name: []const u8,
    items: []const *Node,
};

const MatchResult = struct {
    singles: []const SingleCapture,
    groups: []const GroupCapture,
};

//
// expand phase
//
const ExpandCtx = struct {
    env: *MacroEnv,

    pub fn walk(self: ExpandCtx, allocator: std.mem.Allocator, expr: *Node, _: ExpandCtx) ExpandError!*Node {
        return expandInEnv(allocator, expr, self.env);
    }

    pub fn walkSlice(self: ExpandCtx, allocator: std.mem.Allocator, items: []const *Node, _: ExpandCtx) ExpandError![]*Node {
        return ast.walkSliceWith(allocator, items, ExpandCtx, self);
    }
};

fn expandInEnv(allocator: std.mem.Allocator, expr: *Node, env: *MacroEnv) ExpandError!*Node {
    return switch (expr.expr) {
        .block => |items| blk: {
            var child = try env.clone();
            defer child.deinit();
            break :blk ast.allocNode(allocator, expr.span, .{
                .block = try ast.walkSliceWith(allocator, items, ExpandCtx, .{ .env = &child }),
            });
        },
        .macro_expr => |m| blk: {
            const def = try parseMacroDef(allocator, m.pattern, m.template);
            try env.map.put(m.name, def);
            break :blk ast.allocNode(allocator, Span{ .start = 0, .end = 0, .line = 0, .column = 0 }, .nil);
        },
        .binding => |binding| expandCon(allocator, expr.span, binding, env),
        .decl => |d| ast.allocNode(allocator, expr.span, .{ .decl = .{ .inner = try expandInEnv(allocator, d.inner, env), .kind = d.kind } }),
        .call => |call| maybeExpandCall(allocator, expr.span, call.callee, call.args, call.implicit_self, env),
        .ident => |name| expandIdent(expr, name, env),
        else => ast.walkExpr(allocator, expr, ExpandCtx, .{ .env = env }),
    };
}

fn expandCon(allocator: std.mem.Allocator, span: Span, binding: ast.Binding, env: *MacroEnv) ExpandError!*Node {
    return ast.allocNode(allocator, span, .{ .binding = .{
        .target = try expandInEnv(allocator, binding.target, env),
        .type_name = binding.type_name,
        .value = try expandInEnv(allocator, binding.value, env),
        .mutable = binding.mutable,
    } });
}

fn expandIdent(expr: *Node, name: []const u8, env: *MacroEnv) ExpandError!*Node {
    if (env.map.get(name)) |def| {
        if (def.pattern.len == 0) return instantiateTemplate(env.allocator, expr.span, def.template, &.{}, &.{});
    }
    return expr;
}

fn expandTuplePattern(allocator: std.mem.Allocator, span: Span, items: []const *Node) ExpandError!*Node {
    var out = try std.ArrayList(*Node).initCapacity(allocator, items.len);
    for (items) |item| {
        try out.append(allocator, switch (item.expr) {
            .tuple_pattern => try expandTuplePattern(allocator, item.span, item.expr.tuple_pattern),
            else => @constCast(item),
        });
    }
    return ast.allocNode(allocator, span, .{ .tuple_pattern = try out.toOwnedSlice(allocator) });
}

fn maybeExpandCall(
    allocator: std.mem.Allocator,
    span: Span,
    callee: *Node,
    args: []const *Node,
    implicit_self: bool,
    env: *MacroEnv,
) ExpandError!*Node {
    const expanded_callee = try expandInEnv(allocator, callee, env);
    const expanded_args = try ast.walkSliceWith(allocator, args, ExpandCtx, .{ .env = env });

    if (expanded_callee.expr == .ident) {
        if (env.map.get(expanded_callee.expr.ident)) |def| {
            if (matchPattern(allocator, def.pattern, expanded_args)) |result| {
                return instantiateTemplate(allocator, span, def.template, result.singles, result.groups);
            }
            if (expanded_args.len == 1) {
                if (matchExprPattern(allocator, def.pattern, expanded_args[0])) |result| {
                    return instantiateTemplate(allocator, span, def.template, result.singles, result.groups);
                }
            }
        }
    }

    return ast.allocNode(allocator, span, .{ .call = .{
        .callee = expanded_callee,
        .args = expanded_args,
        .implicit_self = implicit_self,
    } });
}

//
// substitute phase
//
const SubstCtx = struct {
    span: Span,
    replacements: *std.StringHashMap(*Node),

    pub fn walk(self: SubstCtx, allocator: std.mem.Allocator, expr: *Node, _: SubstCtx) ExpandError!*Node {
        return substitutePlaceholders(allocator, self.span, expr, self.replacements);
    }

    pub fn walkSlice(self: SubstCtx, allocator: std.mem.Allocator, items: []const *Node, _: SubstCtx) ExpandError![]*Node {
        return ast.walkSliceWith(allocator, items, SubstCtx, self);
    }
};

fn substitutePlaceholders(
    allocator: std.mem.Allocator,
    span: Span,
    expr: *Node,
    replacements: *std.StringHashMap(*Node),
) ExpandError!*Node {
    if (expr.expr == .ident) {
        return replacements.get(expr.expr.ident) orelse ast.allocNode(allocator, span, expr.expr);
    }
    return ast.walkExpr(allocator, expr, SubstCtx, .{ .span = span, .replacements = replacements });
}

const AstSubstituter = struct {
    allocator: std.mem.Allocator,
    replacements: *const std.StringHashMap(*Node),

    fn substitute(self: *const AstSubstituter, node: *Node) ExpandError!*Node {
        return switch (node.expr) {
            .ident => |name| self.replacements.get(name) orelse node,
            .unary => |u| try self.alloc(node.span, .{
                .unary = .{ .op = u.op, .expr = try self.substitute(u.expr) },
            }),
            .binary => |b| try self.alloc(node.span, .{
                .binary = .{
                    .op = b.op,
                    .left = try self.substitute(b.left),
                    .right = try self.substitute(b.right),
                },
            }),
            .and_expr => |v| try self.alloc(node.span, .{
                .and_expr = .{
                    .left = try self.substitute(v.left),
                    .right = try self.substitute(v.right),
                },
            }),
            .or_expr => |v| try self.alloc(node.span, .{
                .or_expr = .{
                    .left = try self.substitute(v.left),
                    .right = try self.substitute(v.right),
                },
            }),
            .call => |c| blk: {
                var args = try std.ArrayList(*Node).initCapacity(self.allocator, c.args.len);
                defer args.deinit(self.allocator);
                for (c.args) |arg| try args.append(self.allocator, try self.substitute(arg));
                break :blk try self.alloc(node.span, .{
                    .call = .{
                        .callee = try self.substitute(c.callee),
                        .args = try args.toOwnedSlice(self.allocator),
                        .implicit_self = c.implicit_self,
                    },
                });
            },
            .field => |f| try self.alloc(node.span, .{
                .field = .{ .object = try self.substitute(f.object), .name = f.name },
            }),
            .index => |i| try self.alloc(node.span, .{
                .index = .{ .object = try self.substitute(i.object), .key = try self.substitute(i.key) },
            }),
            .if_expr => |v| try self.alloc(node.span, .{
                .if_expr = .{
                    .condition = try self.substitute(v.condition),
                    .then_expr = try self.substitute(v.then_expr),
                    .else_expr = if (v.else_expr) |e| try self.substitute(e) else null,
                },
            }),
            .fn_expr => |f| try self.alloc(node.span, .{
                .fn_expr = .{ .params = f.params, .return_type = f.return_type, .body = try self.substitute(f.body) },
            }),
            .block => |items| blk: {
                var out = try std.ArrayList(*Node).initCapacity(self.allocator, items.len);
                defer out.deinit(self.allocator);
                for (items) |item| try out.append(self.allocator, try self.substitute(item));
                break :blk try self.alloc(node.span, .{ .block = try out.toOwnedSlice(self.allocator) });
            },
            .tuple => |items| blk: {
                var out = try std.ArrayList(*Node).initCapacity(self.allocator, items.len);
                defer out.deinit(self.allocator);
                for (items) |item| try out.append(self.allocator, try self.substitute(item));
                break :blk try self.alloc(node.span, .{ .tuple = try out.toOwnedSlice(self.allocator) });
            },
            .table => |entries| blk: {
                var out = try std.ArrayList(ast.TableEntry).initCapacity(self.allocator, entries.len);
                defer out.deinit(self.allocator);
                for (entries) |entry| {
                    try out.append(self.allocator, .{
                        .key = if (entry.key) |k| try self.substitute(k) else null,
                        .computed = entry.computed,
                        .value = try self.substitute(entry.value),
                    });
                }
                break :blk try self.alloc(node.span, .{ .table = try out.toOwnedSlice(self.allocator) });
            },
            .match_expr => |m| blk: {
                var arms = try std.ArrayList(ast.MatchArm).initCapacity(self.allocator, m.arms.len);
                defer arms.deinit(self.allocator);
                for (m.arms) |arm| {
                    var matchers = try std.ArrayList(ast.MatchMatcher).initCapacity(self.allocator, arm.matchers.len);
                    defer matchers.deinit(self.allocator);
                    for (arm.matchers) |matcher| {
                        switch (matcher) {
                            .wildcard => try matchers.append(self.allocator, .wildcard),
                            .expr => |e| try matchers.append(self.allocator, .{ .expr = try self.substitute(e) }),
                        }
                    }
                    try arms.append(self.allocator, .{
                        .matchers = try matchers.toOwnedSlice(self.allocator),
                        .guard = if (arm.guard) |g| try self.substitute(g) else null,
                        .then = try self.substitute(arm.then),
                    });
                }
                break :blk try self.alloc(node.span, .{
                    .match_expr = .{ .subject = try self.substitute(m.subject), .arms = try arms.toOwnedSlice(self.allocator) },
                });
            },
            .loop_expr => |l| try self.alloc(node.span, .{
                .loop_expr = .{ .body = try self.substitute(l.body) },
            }),
            .for_loop => |f| try self.alloc(node.span, .{
                .for_loop = .{ .params = f.params, .iter = try self.substitute(f.iter), .body = try self.substitute(f.body) },
            }),
            .while_loop => |w| try self.alloc(node.span, .{
                .while_loop = .{ .predicate = try self.substitute(w.predicate), .body = try self.substitute(w.body) },
            }),
            .break_expr => |v| try self.alloc(node.span, .{
                .break_expr = if (v) |inner| try self.substitute(inner) else null,
            }),
            .return_expr => |v| try self.alloc(node.span, .{
                .return_expr = if (v) |inner| try self.substitute(inner) else null,
            }),
            .assign_expr => |a| try self.alloc(node.span, .{
                .assign_expr = .{ .target = try self.substitute(a.target), .value = try self.substitute(a.value) },
            }),
            .binding => |b| {
                try self.alloc(node.span, .{ .binding = .{
                    .target = try self.substitute(b.target),
                    .type_name = b.type_name,
                    .value = try self.substitute(b.value),
                    .mutable = b.mutable,
                } });
            },
            .import_expr => |i| try self.alloc(node.span, .{
                .import_expr = try self.substitute(i),
            }),

            .number, .string, .multiline_string, .hash, .nil, .range_literal, .tuple_pattern, .macro_expr => node,
        };
    }

    fn alloc(self: *const AstSubstituter, span: Span, expr: ast.Expr) ExpandError!*Node {
        const n = try self.allocator.create(Node);
        n.* = .{ .span = span, .expr = expr };
        return n;
    }
};

//
// template instantiation
//
fn instantiateTemplate(
    allocator: std.mem.Allocator,
    span: Span,
    template: []const u8,
    singles: []const SingleCapture,
    groups: []const GroupCapture,
) ExpandError!*Node {
    if (std.mem.indexOf(u8, template, "%<") != null) return error.UnsupportedMacroTemplate;

    var replacements = std.StringHashMap(*Node).init(allocator);
    defer replacements.deinit();

    var builder = TemplateBuilder.init(allocator, singles, groups, &replacements);
    const source = try builder.build(template);
    const parsed = pipeline.parseSource(allocator, source) catch return error.ParseFailed;
    return substitutePlaceholders(allocator, span, parsed, &replacements);
}

const TemplateBuilder = struct {
    allocator: std.mem.Allocator,
    singles: []const SingleCapture,
    groups: []const GroupCapture,
    replacements: *std.StringHashMap(*Node),
    counter: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        singles: []const SingleCapture,
        groups: []const GroupCapture,
        replacements: *std.StringHashMap(*Node),
    ) TemplateBuilder {
        return .{ .allocator = allocator, .singles = singles, .groups = groups, .replacements = replacements };
    }

    fn build(self: *TemplateBuilder, template: []const u8) ExpandError![]const u8 {
        var out = std.ArrayList(u8).empty;
        var i: usize = 0;
        while (i < template.len) {
            if (template[i] != '%') {
                try out.append(self.allocator, template[i]);
                i += 1;
                continue;
            }
            const ref = try self.parseRef(template, i);
            if (ref.group_inner) |inner| {
                try self.appendGroup(&out, ref.name, inner);
            } else {
                try self.appendCapture(&out, ref.name);
            }
            i = ref.next;
        }
        return out.toOwnedSlice(self.allocator);
    }

    const TemplateRef = struct {
        name: []const u8,
        group_inner: ?[]const u8,
        next: usize,
    };

    fn parseRef(self: *TemplateBuilder, template: []const u8, start: usize) ExpandError!TemplateRef {
        _ = self;
        var j = start + 1;
        while (j < template.len and isNameChar(template[j])) : (j += 1) {}
        const name = template[start + 1 .. j];
        if (name.len == 0) return error.UnsupportedMacroTemplate;

        if (j < template.len and template[j] == '(') {
            const close = findMatchingParen(template, j) orelse return error.UnsupportedMacroTemplate;
            return .{ .name = name, .group_inner = template[j + 1 .. close], .next = close + 1 };
        }
        return .{ .name = name, .group_inner = null, .next = j };
    }

    fn appendGroup(self: *TemplateBuilder, out: *std.ArrayList(u8), name: []const u8, inner: []const u8) ExpandError!void {
        const group = findGroup(self.groups, name) orelse return error.UnsupportedMacroTemplate;
        for (group.items, 0..) |item, idx| {
            if (idx > 0) try out.append(self.allocator, ' ');
            var nested = TemplateBuilder.init(
                self.allocator,
                self.singles,
                &.{.{ .name = group.name, .item_name = group.item_name, .items = &.{item} }},
                self.replacements,
            );
            nested.counter = self.counter;
            const text = try nested.build(inner);
            try out.appendSlice(self.allocator, text);
            self.counter = nested.counter;
        }
    }

    fn appendCapture(self: *TemplateBuilder, out: *std.ArrayList(u8), name: []const u8) ExpandError!void {
        const resolved: *Node = blk: {
            if (findSingle(self.singles, name)) |cap| break :blk cap.expr;
            for (self.groups) |group| {
                if (std.mem.eql(u8, group.item_name, name)) {
                    if (group.items.len != 1) return error.UnsupportedMacroTemplate;
                    break :blk @constCast(group.items[0]);
                }
            }
            if (findGroup(self.groups, name)) |group| {
                if (group.items.len != 1) return error.UnsupportedMacroTemplate;
                break :blk @constCast(group.items[0]);
            }
            return error.UnsupportedMacroTemplate;
        };
        try self.appendSentinel(out, name, resolved);
    }

    fn appendSentinel(self: *TemplateBuilder, out: *std.ArrayList(u8), name: []const u8, expr: *Node) !void {
        const sentinel = try std.fmt.allocPrint(self.allocator, "__macro_cap_{s}_{d}", .{ name, self.counter });
        try self.replacements.put(sentinel, expr);
        try out.appendSlice(self.allocator, sentinel);
        self.counter += 1;
    }
};

//
// pattern parse and match
//
fn parseMacroDef(allocator: std.mem.Allocator, pattern_str: []const u8, template_str: []const u8) ExpandError!MacroDef {
    return .{ .pattern = try PatternParser.parse(allocator, pattern_str), .template = template_str };
}

const PatternParser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    fn parse(allocator: std.mem.Allocator, raw: []const u8) ExpandError![]const ast.PatternNode {
        var self = PatternParser{
            .allocator = allocator,
            .text = std.mem.trim(u8, raw, " \t\r\n"),
        };
        return self.parseNodes();
    }

    fn parseNodes(self: *PatternParser) ExpandError![]const ast.PatternNode {
        var nodes = try std.ArrayList(ast.PatternNode).initCapacity(self.allocator, 8);
        defer nodes.deinit(self.allocator);
        while (true) {
            self.skipSpace();
            if (self.pos >= self.text.len) break;
            try nodes.append(self.allocator, try self.parseNode());
        }
        return nodes.toOwnedSlice(self.allocator);
    }

    fn parseNode(self: *PatternParser) ExpandError!ast.PatternNode {
        if (self.text[self.pos] == '%') return self.parseCaptureOrGroup();
        return .{ .literal = try self.parseLiteral() };
    }

    fn parseCaptureOrGroup(self: *PatternParser) ExpandError!ast.PatternNode {
        if (self.pos + 1 < self.text.len and self.text[self.pos + 1] == '<') return error.InvalidIntrospection;
        self.pos += 1;
        const name = self.parseName() orelse return error.UnsupportedMacroPattern;
        if (self.pos < self.text.len and self.text[self.pos] == '(') return self.parseGroup(name);
        return .{ .capture = .{ .name = name, .capture_type = try self.parseCaptureType() } };
    }

    fn parseGroup(self: *PatternParser, name: []const u8) ExpandError!ast.PatternNode {
        const open = self.pos;
        const close = findMatchingParen(self.text, open) orelse return error.UnsupportedMacroPattern;
        const inner = self.text[open + 1 .. close];
        self.pos = close + 1;
        const quantifier = self.parseQuantifier();
        const group_node = try self.allocator.create(ast.GroupNode);
        group_node.* = .{
            .name = name,
            .pattern = try PatternParser.parse(self.allocator, inner),
            .quantifier = quantifier,
        };
        return .{ .group = group_node.* };
    }

    fn parseCaptureType(self: *PatternParser) ExpandError!?ast.CaptureType {
        if (self.pos >= self.text.len or self.text[self.pos] != ':') return null;
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.text.len and std.ascii.isAlphabetic(self.text[self.pos])) : (self.pos += 1) {}
        const type_name = self.text[start..self.pos];
        if (std.mem.eql(u8, type_name, "expr")) return .expr;
        if (std.mem.eql(u8, type_name, "ident")) return .ident;
        if (std.mem.eql(u8, type_name, "str")) return .str;
        if (std.mem.eql(u8, type_name, "number")) return .number;
        if (std.mem.eql(u8, type_name, "call")) return .call;
        return error.UnsupportedMacroPattern;
    }

    fn parseLiteral(self: *PatternParser) ExpandError![]const u8 {
        const start = self.pos;
        while (self.pos < self.text.len and
            (std.ascii.isAlphabetic(self.text[self.pos]) or
                std.ascii.isDigit(self.text[self.pos]) or
                self.text[self.pos] == '_' or
                self.text[self.pos] == '(' or
                self.text[self.pos] == ')' or
                self.text[self.pos] == ',' or
                self.text[self.pos] == ':') and
            !std.ascii.isWhitespace(self.text[self.pos])) : (self.pos += 1)
        {}
        if (self.pos == start) self.pos += 1;
        return self.text[start..self.pos];
    }

    fn parseName(self: *PatternParser) ?[]const u8 {
        const start = self.pos;
        while (self.pos < self.text.len and
            (std.ascii.isAlphabetic(self.text[self.pos]) or
                std.ascii.isDigit(self.text[self.pos]) or
                self.text[self.pos] == '_')) : (self.pos += 1)
        {}
        if (self.pos == start) return null;
        return self.text[start..self.pos];
    }

    fn parseQuantifier(self: *PatternParser) ast.Quantifier {
        if (self.pos >= self.text.len) return .zero_or_more;
        return switch (self.text[self.pos]) {
            '*' => blk: {
                self.pos += 1;
                break :blk .zero_or_more;
            },
            '+' => blk: {
                self.pos += 1;
                break :blk .one_or_more;
            },
            '?' => blk: {
                self.pos += 1;
                break :blk .optional;
            },
            else => .zero_or_more,
        };
    }

    fn skipSpace(self: *PatternParser) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) : (self.pos += 1) {}
    }
};

fn matchPattern(allocator: std.mem.Allocator, pattern: []const ast.PatternNode, args: []const *Node) ?MatchResult {
    var matcher = PatternMatcher.init(allocator, args.len) catch return null;
    defer matcher.deinit();
    if (!matcher.matchNodes(pattern, args)) return null;
    if (matcher.arg_idx != args.len) return null;
    return matcher.finish();
}

fn matchExprPattern(allocator: std.mem.Allocator, pattern: []const ast.PatternNode, expr: *Node) ?MatchResult {
    var matcher = PatternMatcher.init(allocator, 2) catch return null;
    defer matcher.deinit();

    switch (expr.expr) {
        .assign_expr => |assign| {
            if (pattern.len != 3) return null;
            if (!matcher.matchNodeToExpr(pattern[0], assign.target)) return null;
            switch (pattern[1]) {
                .literal => |lit| if (!std.mem.eql(u8, lit, "=")) return null,
                else => return null,
            }
            if (!matcher.matchNodeToExpr(pattern[2], assign.value)) return null;
        },
        else => {
            if (pattern.len != 1) return null;
            if (!matcher.matchNodeToExpr(pattern[0], expr)) return null;
        },
    }

    return matcher.finish();
}

const PatternMatcher = struct {
    allocator: std.mem.Allocator,
    singles: std.ArrayList(SingleCapture),
    groups: std.ArrayList(GroupCapture),
    arg_idx: usize = 0,

    fn init(allocator: std.mem.Allocator, single_cap: usize) !PatternMatcher {
        var self = PatternMatcher{
            .allocator = allocator,
            .singles = undefined,
            .groups = undefined,
        };
        self.singles = try std.ArrayList(SingleCapture).initCapacity(allocator, single_cap);
        errdefer self.singles.deinit(allocator);
        self.groups = try std.ArrayList(GroupCapture).initCapacity(allocator, 8);
        errdefer self.groups.deinit(allocator);
        
        return self;
    }

    fn deinit(self: *PatternMatcher) void {
        self.singles.deinit(self.allocator);
        self.groups.deinit(self.allocator);
    }

    fn finish(self: *PatternMatcher) ?MatchResult {
        return .{
            .singles = self.singles.toOwnedSlice(self.allocator) catch return null,
            .groups = self.groups.toOwnedSlice(self.allocator) catch return null,
        };
    }

    fn matchNodes(self: *PatternMatcher, pattern: []const ast.PatternNode, args: []const *Node) bool {
        for (pattern) |node| {
            switch (node) {
                .literal => {},
                .capture => |capture| {
                    if (self.arg_idx >= args.len) return false;
                    if (!self.matchCapture(capture, args[self.arg_idx])) return false;
                    self.arg_idx += 1;
                },
                .group => |group| if (!self.matchGroup(group, args)) return false,
                .sequence => return false,
            }
        }
        return true;
    }

    fn matchNodeToExpr(self: *PatternMatcher, node: ast.PatternNode, expr: *Node) bool {
        return switch (node) {
            .capture => |capture| self.matchCapture(capture, expr),
            else => false,
        };
    }

    fn matchCapture(self: *PatternMatcher, capture: ast.CaptureNode, expr: *Node) bool {
        if (!captureMatches(capture.capture_type, expr)) return false;
        self.singles.append(self.allocator, .{ .name = capture.name, .expr = expr }) catch return false;
        return true;
    }

    fn matchGroup(self: *PatternMatcher, group: ast.GroupNode, args: []const *Node) bool {
        var items = std.ArrayList(*Node).initCapacity(self.allocator, 8) catch return false;
        const item_name = firstCaptureName(group.pattern) orelse "";
        var match_count: usize = 0;

        while (self.arg_idx < args.len) {
            const next = self.matchGroupIteration(group.pattern, args, self.arg_idx) orelse break;
            for (next.captures) |capture| {
                items.append(self.allocator, capture.expr) catch return false;
            }
            self.allocator.free(next.captures);
            self.arg_idx = next.arg_idx;
            match_count += 1;
        }

        switch (group.quantifier) {
            .zero_or_more => {},
            .one_or_more => if (match_count == 0) return false,
            .optional => if (match_count > 1) return false,
        }

        self.groups.append(self.allocator, .{
            .name = group.name,
            .item_name = item_name,
            .items = items.toOwnedSlice(self.allocator) catch return false,
        }) catch return false;
        return true;
    }

    const GroupIteration = struct {
        captures: []const SingleCapture,
        arg_idx: usize,
    };

    fn matchGroupIteration(self: *PatternMatcher, pattern: []const ast.PatternNode, args: []const *Node, start: usize) ?GroupIteration {
        var captures = std.ArrayList(SingleCapture).initCapacity(self.allocator, 4) catch return null;
        var arg_idx = start;
        for (pattern) |node| {
            switch (node) {
                .literal => {},
                .capture => |capture| {
                    if (arg_idx >= args.len) {
                        captures.deinit(self.allocator);
                        return null;
                    }
                    if (!captureMatches(capture.capture_type, args[arg_idx])) {
                        captures.deinit(self.allocator);
                        return null;
                    }
                    captures.append(self.allocator, .{ .name = capture.name, .expr = args[arg_idx] }) catch {
                        captures.deinit(self.allocator);
                        return null;
                    };
                    arg_idx += 1;
                },
                else => {
                    captures.deinit(self.allocator);
                    return null;
                },
            }
        }
        return .{ .captures = captures.toOwnedSlice(self.allocator) catch return null, .arg_idx = arg_idx };
    }
};

fn captureMatches(capture_type: ?ast.CaptureType, expr: *Node) bool {
    const cap_type = capture_type orelse return true;
    return switch (cap_type) {
        .expr => true,
        .ident => expr.expr == .ident,
        .str => expr.expr == .string,
        .number => expr.expr == .number,
        .call => expr.expr == .call,
    };
}

fn firstCaptureName(pattern: []const ast.PatternNode) ?[]const u8 {
    for (pattern) |node| {
        if (node == .capture) return node.capture.name;
    }
    return null;
}

fn findSingle(singles: []const SingleCapture, name: []const u8) ?SingleCapture {
    for (singles) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn findGroup(groups: []const GroupCapture, name: []const u8) ?GroupCapture {
    for (groups) |g| if (std.mem.eql(u8, g.name, name)) return g;
    return null;
}

fn findMatchingParen(text: []const u8, open_idx: usize) ?usize {
    var depth: usize = 0;
    var i = open_idx;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_' or c == '!' or c == '?';
}

pub const testing = struct {
    fn doesMatch(got: *Node, wanted: []const u8) !void {
        var buf = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer buf.deinit();
        try got.print(&buf.writer);
        try std.testing.expectEqualStrings(wanted, buf.written());
    }

    test "expands zero-arg and unary macros" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const expanded = try expandExpr(arena.allocator(), try pipeline.parseSource(arena.allocator(),
            \\ macro dup! `` `saved`
            \\ macro try! `%e:expr` `match %e | x when is_error(x) => sys.panic(x) | x => x`
            \\ 41
            \\ dup!
            \\ try!(1)
        ));
        var buf = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer buf.deinit();
        try expanded.print(&buf.writer);
        try std.testing.expectEqualStrings(
            "(block nil nil 41 saved (match 1 (arm x (when (call is_error x)) (call (field sys panic) x)) (arm x x)))",
            buf.written(),
        );
    }

    test "expands println and pipe macros" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const expanded = try expandExpr(arena.allocator(), try pipeline.parseSource(arena.allocator(),
            \\ macro println! `(%fmt:str %ARGS(, %arg:expr)*)` `(print(fmt(%fmt %ARGS(, %arg))))`
            \\ "yo"
            \\ println!("%v %v", 1, 2)
        ));
        try doesMatch(expanded, "(block nil \"yo\" (call print (call fmt \"%v %v\" 1 2)))");
    }

    test "expands binary macro with multiple captures and literals" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const expanded = try expandExpr(arena.allocator(), try pipeline.parseSource(arena.allocator(),
            \\ macro add! `%a:expr + %b:expr` `(%a + %b)`
            \\ add!(1, 2)
        ));
        try doesMatch(expanded, "(block nil (+ 1 2))");
    }

    test "expands variadic group capture macro" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const expanded = try expandExpr(arena.allocator(), try pipeline.parseSource(arena.allocator(),
            \\ macro sum! `%first:expr %REST(%item:expr)*` `%first %REST(+ %item)`
            \\ sum!(1, 2, 3)
        ));
        try doesMatch(expanded, "(block nil (+ (+ 1 2) 3))");
    }

    test "expands unless macro" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const expanded = try expandExpr(arena.allocator(), try pipeline.parseSource(arena.allocator(),
            \\ macro unless! `(%cond:expr %body:expr)` `if %cond nil else %body`
            \\ unless!(:false, 42)
        ));
        try doesMatch(expanded, "(block nil (if :false nil 42))");
    }

    test "expands ok and err result macros" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const expanded = try expandExpr(arena.allocator(), try pipeline.parseSource(arena.allocator(),
            \\ macro ok! `(%what:expr)` `(:ok, %what)`
            \\ macro err! `(%what:expr)` `(:err, %what)`
            \\ ok!(42)
            \\ err!("fail")
        ));
        try doesMatch(expanded, "(block nil nil (tuple :ok 42) (tuple :err \"fail\"))");
    }

    test "expands all_true macro" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const expanded = try expandExpr(arena.allocator(), try pipeline.parseSource(arena.allocator(),
            \\ macro all_true! `(%ITEMS(%item:expr)*)` `do :true %ITEMS(and (%item and :true)) end`
            \\ all_true!(1, :true)
        ));
        try doesMatch(expanded, "(block nil (block (and (and :true (and 1 :true)) (and :true :true))))");
    }

    test "macro in nested block scope" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const expanded = try expandExpr(arena.allocator(), try pipeline.parseSource(arena.allocator(),
            \\ macro double! `%x:expr` `(%x * 2)`
            \\ do
            \\   macro triple! `%x:expr` `(%x * 3)`
            \\   double!(5)
            \\   triple!(5)
            \\ end
        ));
        try doesMatch(expanded, "(block nil (block nil (* 5 2) (* 5 3)))");
    }

    test "macro capture type restrictions" {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const expanded = try expandExpr(arena.allocator(), try pipeline.parseSource(arena.allocator(),
            \\ macro id! `%x:ident` `%x`
            \\ macro num! `%x:number` `%x`
            \\ id!(foo)
            \\ num!(42)
        ));
        try doesMatch(expanded, "(block nil nil foo 42)");
    }
};
