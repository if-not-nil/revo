//! `.interpolated` sugar to `(call fmt format args...)`
//! , idempotent

const std = @import("std");

const cst = @import("../cst.zig");
const Lexer = @import("../Lexer.zig");
const Node = cst.CstNode;

pub fn lowerRoot(alloc: std.mem.Allocator, root: *Node) std.mem.Allocator.Error!*Node {
    return Lower.walk(.{}, alloc, root, .{});
}

const Lower = struct {
    pub fn walk(_: @This(), allocator: std.mem.Allocator, expr: *Node, ctx: @This()) std.mem.Allocator.Error!*Node {
        const walked = try cst.walkCstExpr(allocator, expr, @This(), ctx);
        if (walked.kind == .interpolated) return lowerOne(allocator, walked);
        return walked;
    }
};

/// `%` doubles inside `fmt` formats so literal percents survive
fn appendFormatLiteral(out: *std.ArrayList(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '%') try out.append(alloc, '%');
        try out.append(alloc, text[i]);
        i += 1;
    }
}

fn placeholder(mode: cst.InterpolationMode) []const u8 {
    return switch (mode) {
        .plain => "%v",
        .debug => "%?",
        .pretty => "%p",
    };
}

fn lowerOne(alloc: std.mem.Allocator, node: *Node) std.mem.Allocator.Error!*Node {
    const t = node.kind.interpolated;
    var has_interp = false;

    for (t.parts) |part| if (part == .interp) {
        has_interp = true;
        break;
    };

    if (!has_interp) {
        // plain string fold (multiline dedents like lowering did)
        var text = try std.ArrayList(u8).initCapacity(alloc, 32);
        defer text.deinit(alloc);
        for (t.parts) |part| try text.appendSlice(alloc, part.literal.text);
        const raw = try text.toOwnedSlice(alloc);

        if (t.multiline) {
            defer alloc.free(raw);
            const dedented = try Lexer.dedentMultiline(alloc, raw);
            return cst.allocNode(alloc, node.span, .{ .string = .{ .tok = cst.syntheticToken(dedented, node.span) } });
        }
        return cst.allocNode(alloc, node.span, .{ .string = .{ .tok = cst.syntheticToken(raw, node.span) } });
    }

    var format = try std.ArrayList(u8).initCapacity(alloc, 32);
    errdefer format.deinit(alloc);
    var args = try std.ArrayList(*Node).initCapacity(alloc, t.parts.len);
    errdefer args.deinit(alloc);

    for (t.parts) |part| switch (part) {
        .literal => |tok| try appendFormatLiteral(&format, alloc, tok.text),
        .interp => |in| {
            try args.append(alloc, in.value);
            try format.appendSlice(alloc, placeholder(in.mode));
        },
    };

    var fmt_text: []const u8 = try format.toOwnedSlice(alloc);
    if (t.multiline) {
        errdefer alloc.free(fmt_text);
        const dedented = try Lexer.dedentMultiline(alloc, fmt_text);
        alloc.free(fmt_text);
        fmt_text = dedented;
    }

    // synthesize `fmt("<format>", args...)` call with fake tokens
    const span = node.span;
    const fmt_tok = cst.syntheticToken("fmt", span);
    const str_tok = cst.syntheticToken(fmt_text, span);

    // string node text borrows fmt_text; token text is the same slice
    var call_args = try std.ArrayList(*Node).initCapacity(alloc, args.items.len + 1);
    errdefer call_args.deinit(alloc);

    try call_args.append(alloc, try cst.allocNode(alloc, span, .{ .string = .{ .tok = str_tok } }));
    try call_args.appendSlice(alloc, args.items);
    args.deinit(alloc);

    const callee = try cst.allocNode(alloc, span, .{ .ident = .{ .tok = fmt_tok } });

    return cst.allocNode(alloc, span, .{ .call = .{
        .callee = callee,
        .lparen_tok = cst.syntheticToken("(", span),
        .args = try call_args.toOwnedSlice(alloc),
        .commas = &.{},
        .rparen_tok = cst.syntheticToken(")", span),
    } });
}

test "lowers sugar to a fmt call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const span: Lexer.Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 };

    const name = try cst.allocIdent(alloc, span, "name");
    const open = cst.syntheticToken("#{", span);
    const close = cst.syntheticToken("}", span);
    const root = try cst.allocNode(alloc, span, .{ .interpolated = .{
        .start_tok = cst.syntheticToken("\"", span),
        .parts = try alloc.dupe(cst.CstInterpPart, &.{
            .{ .literal = cst.syntheticToken("hello ", span) },
            .{ .interp = .{ .open_tok = open, .value = name, .mode = .plain, .mode_tok = null, .close_tok = close } },
            .{ .literal = cst.syntheticToken("100% ", span) },
            .{ .interp = .{ .open_tok = open, .value = name, .mode = .debug, .mode_tok = null, .close_tok = close } },
        }),
        .end_tok = cst.syntheticToken("\"", span),
        .multiline = false,
    } });

    const lowered = try lowerRoot(alloc, root);
    try std.testing.expect(lowered.kind == .call);
    try std.testing.expectEqualStrings("fmt", lowered.kind.call.callee.kind.ident.tok.text);
    try std.testing.expectEqual(@as(usize, 3), lowered.kind.call.args.len);
    try std.testing.expectEqualStrings("hello %v100%% %?", lowered.kind.call.args[0].kind.string.tok.text);

    // multiline dedents the assembled format (literals + placeholders)
    const ml = try cst.allocNode(alloc, span, .{ .interpolated = .{
        .start_tok = cst.syntheticToken("\"\"\"", span),
        .parts = try alloc.dupe(cst.CstInterpPart, &.{
            .{ .literal = cst.syntheticToken("\n  hello ", span) },
            .{ .interp = .{ .open_tok = open, .value = name, .mode = .plain, .mode_tok = null, .close_tok = close } },
            .{ .literal = cst.syntheticToken("\n  ", span) },
        }),
        .end_tok = cst.syntheticToken("\"\"\"", span),
        .multiline = true,
    } });
    const lowered_ml = try lowerRoot(alloc, ml);
    try std.testing.expectEqualStrings("hello %v", lowered_ml.kind.call.args[0].kind.string.tok.text);

    // idempotent: no sugar left, rerun rebuilds the same shape
    const twice = try lowerRoot(alloc, lowered);
    try std.testing.expect(twice.kind == .call);
    try std.testing.expectEqual(@as(usize, 3), twice.kind.call.args.len);
}
