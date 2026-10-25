//! text and position utilities for the workspace
//! owns the shared vocabulary (FileId, Position, Range, Location) so
//! providers import one leaf instead of the whole workspace

const std = @import("std");

const cst = @import("../cst.zig");
const Lexer = @import("../Lexer.zig");
const Parser = @import("../Parser.zig");

pub const FileId = u32;

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    file_id: FileId,
    name: []const u8,
    range: Range,
};

/// extract a single source line by line index (1-based)
pub fn sourceLine(src: []const u8, line: u32) []const u8 {
    var pos: usize = 0;
    var cur: u32 = 1;
    while (cur < line and pos < src.len) {
        if (src[pos] == '\n') cur += 1;
        pos += 1;
    }
    const end = std.mem.findScalarPos(u8, src, pos, '\n') orelse src.len;
    return src[pos..end];
}

pub fn positionToOffset(src: []const u8, pos: Position) ?usize {
    var line: u32 = 1;
    var col: u32 = 1;
    for (src, 0..) |ch, idx| {
        if (line == pos.line and col == pos.character) return idx;
        if (ch == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    if (line == pos.line and col == pos.character) return src.len;
    return null;
}

pub fn offsetToPosition(src: []const u8, offset: usize) Position {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < offset and i < src.len) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}

pub fn wordAtPosition(src: []const u8, pos: Position) ?[]const u8 {
    const offset = positionToOffset(src, pos) orelse return null;
    if (offset >= src.len) return null;
    var start = offset;
    while (start > 0 and isWordChar(src[start - 1])) start -= 1;
    var end = offset;
    while (end < src.len and isWordChar(src[end])) end += 1;
    if (end <= start) return null;
    return src[start..end];
}

pub fn isWordChar(c: u8) bool {
    // `?`/`!` suffix names (`exists?`) are single identifiers
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '?' or c == '!';
}

/// the whole word under pos, wherever the cursor sits inside it
pub fn wordRangeAt(src: []const u8, pos: Position) ?Range {
    const offset = positionToOffset(src, pos) orelse return null;
    if (offset >= src.len) return null;
    var start = offset;
    while (start > 0 and isWordChar(src[start - 1])) start -= 1;
    var end = offset;
    while (end < src.len and isWordChar(src[end])) end += 1;
    if (end <= start) return null;
    return .{
        .start = offsetToPosition(src, start),
        .end = offsetToPosition(src, end),
    };
}

pub fn positionBefore(a: Position, b: Position) bool {
    return a.line < b.line or (a.line == b.line and a.character <= b.character);
}

pub fn containsId(items: []const FileId, id: FileId) bool {
    for (items) |item|
        if (item == id) return true;

    return false;
}

/// does a dep file serve as the module named `name`? plain modules match by
/// stem (`foo.rv` -> `foo`)
pub fn moduleFileNameMatches(snap_name: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, std.Io.Dir.path.stem(snap_name), name)) return true;
    return false;
}

/// text before the final newline
/// : the in-progress line cannot parse
///   , so dep lookups during completion ignore it
pub fn stripLastLine(src: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, src, "\r\n");
    const idx = std.mem.findScalarLast(u8, trimmed, '\n') orelse return "";
    return trimmed[0..idx];
}

/// strip leading `pub ` from a line
pub fn stripPub(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, line, "pub ")) return line[4..];
    return line;
}

/// if the word at pos is a member of an import binding (`mod.member`),
/// return the module name
pub fn moduleMemberAt(src: []const u8, pos: Position) ?[]const u8 {
    const offset = positionToOffset(src, pos) orelse return null;
    var start = offset;
    while (start > 0 and isWordChar(src[start - 1])) start -= 1;
    if (start >= offset) return null;
    var i = start;
    while (i > 0 and (src[i - 1] == ' ' or src[i - 1] == '\t')) i -= 1;
    if (i == 0 or src[i - 1] != '.') return null;
    i -= 1;
    while (i > 0 and (src[i - 1] == ' ' or src[i - 1] == '\t')) i -= 1;
    var mod_start = i;
    while (mod_start > 0 and isWordChar(src[mod_start - 1])) mod_start -= 1;
    if (mod_start >= i) return null;
    return src[mod_start..i];
}

/// result from text scan for a call at cursor
pub const CallAtPos = struct {
    name: []const u8,
    active_param: u32,
};

/// scan backward from pos to find the enclosing function call, return
/// the callee name and which argument the cursor is inside
pub fn findCallAtPosition(src: []const u8, pos: Position) ?CallAtPos {
    const offset = positionToOffset(src, pos) orelse return null;
    if (offset == 0 or offset > src.len) return null;

    var depth: i32 = 0;
    var i = offset;
    if (i == src.len) i -= 1;
    while (i > 0) : (i -= 1) {
        switch (src[i]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) {
                    var start = i;
                    while (start > 0 and isWordChar(src[start - 1])) start -= 1;
                    if (start < i) {
                        const name = src[start..i];
                        var active: u32 = 0;
                        var j = i + 1;
                        var inner_depth: i32 = 0;
                        while (j < offset) : (j += 1) {
                            switch (src[j]) {
                                '(' => inner_depth += 1,
                                ')' => inner_depth -= 1,
                                ',' => {
                                    if (inner_depth == 0) active += 1;
                                },
                                else => {},
                            }
                        }
                        return .{ .name = name, .active_param = active };
                    }
                }
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// walk cst to build a map of byte offset -> semantic token type
pub fn cstSpanMapFromRoot(arena: std.mem.Allocator, root: *const cst.CstNode) ?std.AutoHashMap(usize, u32) {
    var map = std.AutoHashMap(usize, u32).init(arena);
    walkRoles(root, &map) catch return null;
    return map;
}

/// parse `source` and build its role map (source-string entry point)
pub fn buildCstSpanMap(arena: std.mem.Allocator, source: []const u8) ?std.AutoHashMap(usize, u32) {
    const parsed = Parser.parseSourceReport(arena, source, .{}) catch return null;
    const root = switch (parsed) {
        .ok => |n| n,
        .err => return null,
    };
    return cstSpanMapFromRoot(arena, root);
}

fn calleeIdent(n: *const cst.CstNode) ?[]const u8 {
    const u = cst.unwrapParen(n) orelse return null;
    if (u.kind == .ident) return u.kind.ident.tok.text;
    return null;
}

fn walkRoles(n: *const cst.CstNode, m: *std.AutoHashMap(usize, u32)) !void {
    switch (n.kind) {
        .call => |c| {
            try walkRoles(c.callee, m);
            const cu = cst.unwrapParen(c.callee);
            if (cu != null and cu.?.kind == .ident) try m.put(c.callee.span.start, @backingInt(Lexer.TokenClass.function));
            if (cu != null and cu.?.kind == .field) {
                const fname = cu.?.kind.field.name_tok.text;
                try m.put(c.callee.span.end - fname.len, @backingInt(Lexer.TokenClass.function));
            }
            for (c.args) |a| try walkRoles(a, m);
        },
        .bare_call => |b| {
            try walkRoles(b.callee, m);
            if (calleeIdent(b.callee) != null) try m.put(b.callee.span.start, @backingInt(Lexer.TokenClass.function));
            try walkRoles(b.arg, m);
        },
        .generic_call => |g| {
            try walkRoles(g.receiver, m);
            for (g.args) |a| try walkRoles(a, m);
        },
        .method_call => |mc| {
            try walkRoles(mc.object, m);
            const aname = mc.atom_tok.text;
            try m.put(n.span.end - aname.len, @backingInt(Lexer.TokenClass.function));
            for (mc.args) |a| try walkRoles(a, m);
        },
        .binding => |b| {
            const tu = cst.unwrapParen(b.target);
            if (tu != null and tu.?.kind == .ident) {
                const vu = cst.unwrapParen(b.value);
                const is_fn = if (vu) |v| v.kind == .fn_def else false;
                try m.put(b.target.span.start, if (is_fn) @backingInt(Lexer.TokenClass.function) else @backingInt(Lexer.TokenClass.variable));
            }
            try walkRoles(b.target, m);
            try walkRoles(b.value, m);
        },
        .field => |f| {
            try m.put(n.span.end - f.name_tok.text.len, @backingInt(Lexer.TokenClass.variable));
            try walkRoles(f.object, m);
        },
        .dotted_index => |d| try walkRoles(d.object, m),
        .unary => |u| try walkRoles(u.expr, m),
        .yield => {},
        .binary => |b| {
            try walkRoles(b.left, m);
            try walkRoles(b.right, m);
        },
        .logical => |l| {
            try walkRoles(l.left, m);
            try walkRoles(l.right, m);
        },
        .compound => |c| {
            try walkRoles(c.target, m);
            try walkRoles(c.value, m);
        },
        .assign => |a| {
            try walkRoles(a.target, m);
            try walkRoles(a.value, m);
        },
        .if_expr => |v| {
            try walkRoles(v.cond, m);
            try walkRoles(v.then, m);
            if (v.else_) |e| try walkRoles(e, m);
        },
        .index => |idx| {
            try walkRoles(idx.object, m);
            try walkRoles(idx.key, m);
        },
        .return_expr => |v| {
            if (v.value) |e| try walkRoles(e, m);
        },
        .break_expr => |v| {
            if (v.value) |e| try walkRoles(e, m);
        },
        .continue_expr => {},
        .match => |v| {
            if (v.subject) |st| try walkRoles(st, m);
            for (v.arms) |arm| {
                for (arm.matchers) |matcher| {
                    if (matcher == .expr) try walkRoles(matcher.expr, m);
                }
                if (arm.guard) |g| try walkRoles(g, m);
                try walkRoles(arm.then, m);
            }
        },
        .for_loop => |v| {
            try walkRoles(v.iter, m);
            try walkRoles(v.body, m);
        },
        .while_loop => |v| {
            try walkRoles(v.pred, m);
            try walkRoles(v.body, m);
        },
        .loop_expr => |v| try walkRoles(v.body, m),
        .range => |v| {
            try walkRoles(v.start, m);
            try walkRoles(v.mid, m);
            if (v.end) |e| try walkRoles(e, m);
        },
        .for_range => |v| {
            if (v.start) |st| try walkRoles(st, m);
            if (v.mid) |md| try walkRoles(md, m);
            if (v.end) |e| try walkRoles(e, m);
        },
        .slice => |v| {
            if (v.start) |st| try walkRoles(st, m);
            if (v.mid) |md| try walkRoles(md, m);
            if (v.end) |e| try walkRoles(e, m);
        },
        .table => |tbl| {
            for (tbl.entries) |e| switch (e) {
                .computed => |cc| {
                    try walkRoles(cc.key, m);
                    try walkRoles(cc.value, m);
                },
                .keyed => |k| {
                    try walkRoles(k.key, m);
                    try walkRoles(k.value, m);
                },
                .bare => |b| try walkRoles(b.value, m),
            };
        },
        .ascribed => |a| try walkRoles(a.expr, m),
        .comp_block => |v| try walkRoles(v.expr, m),
        .block => |b| {
            for (b.stmts) |e| try walkRoles(e, m);
        },
        .root => |r| {
            for (r.stmts) |e| try walkRoles(e, m);
        },
        .do_block => |d| {
            for (d.stmts) |e| try walkRoles(e, m);
        },
        .paren => |p| if (p.expr) |e| try walkRoles(e, m),
        .pipe => |p| {
            try walkRoles(p.left, m);
            try walkRoles(p.right, m);
        },
        .try_expr => |t| try walkRoles(t.expr, m),
        .test_block => |v| try walkRoles(v.body, m),
        .test_suite => |v| try walkRoles(v.body, m),
        .decl => |d| try walkRoles(d.inner, m),
        .fn_def => |f| {
            for (f.params) |p| {
                if (p.default) |dd| try walkRoles(dd, m);
            }
            try walkRoles(f.body, m);
        },
        .fn_method => |f| try walkRoles(f.body, m),
        .import, .type_alias, .number, .string, .atom, .ident, .err, .interpolated => {},
    }
}

test "offset roundtrips through position" {
    const src = "ab\ncd";
    try std.testing.expectEqual(@as(?usize, 0), positionToOffset(src, .{ .line = 1, .character = 1 }));
    try std.testing.expectEqual(@as(?usize, 3), positionToOffset(src, .{ .line = 2, .character = 1 }));
    try std.testing.expectEqual(Position{ .line = 2, .character = 1 }, offsetToPosition(src, 3));
}

test "sourceLine picks 1-based lines" {
    const src = "one\ntwo\nthree";
    try std.testing.expectEqualStrings("two", sourceLine(src, 2));
}

test "word utils include ? suffix" {
    const src = "exists? foo";
    try std.testing.expectEqualStrings("exists?", wordAtPosition(src, .{ .line = 1, .character = 2 }).?);
    const r = wordRangeAt(src, .{ .line = 1, .character = 2 }).?;
    try std.testing.expectEqual(@as(u32, 1), r.start.character);
    try std.testing.expectEqual(@as(u32, 8), r.end.character);
}

test "stripLastLine drops in-progress line" {
    try std.testing.expectEqualStrings("a", stripLastLine("a\nb"));
}

test "module file matches stem" {
    try std.testing.expect(moduleFileNameMatches("foo.rv", "foo"));
    try std.testing.expect(!moduleFileNameMatches("bar.rv", "foo"));
}
