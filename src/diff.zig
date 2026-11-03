//! super small line diff for `revo fmt --diff` and the lsp's format edits
//! , exact (lcs) for small edits, one coarse hunk when the whole file
//!   changed, which is the common case for a reformat
//!
//! i have no idea what any of this does anymore

const std = @import("std");

/// unchanged lines shown around a hunk
const context = 3;

/// above this many lcs cells the table is skipped
/// a full reformat shares almost nothing
/// so one hunk over the middle is the good one
const max_cells: usize = 1 << 20;

const Op = struct {
    kind: enum { equal, del, ins },
    text: []const u8,
    /// the line of `new` an `equal` pairs with; only whitespace can differ
    new: []const u8 = "",
};

/// write `old` -> `new` as a diff, `name` is the path
pub fn write(out: *std.Io.Writer, name: []const u8, old: []const u8, new: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try out.print("--- {s}\n+++ {s}\n", .{ name, name });
    try hunks(out, try script(arena, try split(arena, old, false), try split(arena, new, false), false), 1);
}

/// `old[start..end]` becomes `text`, a slice of `new`
pub const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

/// the changed lines that turn `old` into `new`, in order and never
/// overlapping, for an editor that should keep its cursor and undo history
pub fn edits(arena: std.mem.Allocator, old: []const u8, new: []const u8) ![]const Edit {
    // lines keep their `\n`, so a missing last newline is a change too; they
    // pair up past whitespace, so each reindented line is its own edit
    const ops = try script(arena, try split(arena, old, true), try split(arena, new, true), true);
    var out: std.ArrayList(Edit) = .empty;
    var at: usize = 0;
    var new_at: usize = 0;
    var i: usize = 0;
    while (i < ops.len) {
        const op = ops[i];
        if (op.kind == .equal) {
            if (!std.mem.eql(u8, op.text, op.new)) try out.append(arena, .{ .start = at, .end = at + op.text.len, .text = op.new });
            at += op.text.len;
            new_at += op.new.len;
            i += 1;
            continue;
        }
        const start = at;
        const new_start = new_at;
        while (i < ops.len and ops[i].kind != .equal) : (i += 1) switch (ops[i].kind) {
            .del => at += ops[i].text.len,
            .ins => new_at += ops[i].text.len,
            .equal => unreachable,
        };
        try out.append(arena, .{ .start = start, .end = at, .text = new[new_start..new_at] });
    }
    return out.items;
}

/// `old` with `changes` from `edits` made
pub fn apply(arena: std.mem.Allocator, old: []const u8, changes: []const Edit) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (changes) |c| {
        try out.appendSlice(arena, old[at..c.start]);
        try out.appendSlice(arena, c.text);
        at = c.end;
    }
    try out.appendSlice(arena, old[at..]);
    return out.items;
}

/// every line of `a` and `b` as equal, deleted or inserted; `loose` lets
/// lines that differ only in whitespace pair up as equal
fn script(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8, loose: bool) ![]const Op {
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and same(loose, a[pre], b[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and
        same(loose, a[a.len - 1 - suf], b[b.len - 1 - suf])) suf += 1;
    const mid_a = a[pre .. a.len - suf];
    const mid_b = b[pre .. b.len - suf];

    var ops: std.ArrayList(Op) = .empty;
    for (a[0..pre], b[0..pre]) |x, y| try ops.append(arena, .{ .kind = .equal, .text = x, .new = y });
    // a full reformat:
    //   every line differs, no table needed
    if (mid_a.len * mid_b.len > max_cells) {
        for (mid_a) |line| try ops.append(arena, .{ .kind = .del, .text = line });
        for (mid_b) |line| try ops.append(arena, .{ .kind = .ins, .text = line });
    } else try ops.appendSlice(arena, try lcs(arena, mid_a, mid_b, loose));
    for (a[a.len - suf ..], b[b.len - suf ..]) |x, y| try ops.append(arena, .{ .kind = .equal, .text = x, .new = y });
    return ops.items;
}

/// `loose` skips whitespace, so a reindented or respaced line still matches
fn same(loose: bool, x: []const u8, y: []const u8) bool {
    if (!loose) return std.mem.eql(u8, x, y);
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < x.len and std.ascii.isWhitespace(x[i])) i += 1;
        while (j < y.len and std.ascii.isWhitespace(y[j])) j += 1;
        if (i == x.len or j == y.len) return i == x.len and j == y.len;
        if (x[i] != y[j]) return false;
        i += 1;
        j += 1;
    }
}

/// hunks with `context` lines around each change, nearby changes merged
fn hunks(out: *std.Io.Writer, ops: []const Op, start_line: usize) !void {
    var old_line = start_line;
    var new_line = start_line;
    var i: usize = 0;
    while (i < ops.len) {
        if (ops[i].kind == .equal) {
            old_line += 1;
            new_line += 1;
            i += 1;
            continue;
        }

        var start = i;
        var back: usize = 0;
        while (start > 0 and ops[start - 1].kind == .equal and back < context) : (back += 1) start -= 1;

        var end = i;
        while (true) {
            while (end < ops.len and ops[end].kind != .equal) end += 1;
            var look = end;
            while (look < ops.len and ops[look].kind == .equal) look += 1;
            if (look < ops.len and look - end <= context * 2) {
                end = look;
                continue;
            }
            end = @min(end + context, look);
            break;
        }

        var old_count: usize = 0;
        var new_count: usize = 0;
        for (ops[start..end]) |op| switch (op.kind) {
            .equal => {
                old_count += 1;
                new_count += 1;
            },
            .del => old_count += 1,
            .ins => new_count += 1,
        };
        try out.print("@@ -{d},{d} +{d},{d} @@\n", .{
            old_line - back,
            old_count,
            new_line - back,
            new_count,
        });
        for (ops[start..end]) |op| switch (op.kind) {
            .equal => try out.print(" {s}\n", .{op.text}),
            .del => try out.print("-{s}\n", .{op.text}),
            .ins => try out.print("+{s}\n", .{op.text}),
        };

        // advance the counters past this hunk
        for (ops[i..end]) |op| switch (op.kind) {
            .equal => {
                old_line += 1;
                new_line += 1;
            },
            .del => old_line += 1,
            .ins => new_line += 1,
        };
        i = end;
    }
}

/// split into lines, with or without their `\n`
/// a final newline does not make an empty last line
fn split(arena: std.mem.Allocator, text: []const u8, keep_newline: bool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try out.append(arena, text[start..if (keep_newline) @min(nl + 1, text.len) else nl]);
        start = nl + 1;
    }
    return out.toOwnedSlice(arena);
}

/// lcs of lines, backtracked into edit script
fn lcs(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8, loose: bool) ![]const Op {
    // i have no idea what this function does anymore
    const w = b.len + 1;
    const table = try arena.alloc(u32, (a.len + 1) * w);

    @memset(table, 0);
    for (1..a.len + 1) |i| {
        for (1..b.len + 1) |j| {
            table[i * w + j] = if (same(loose, a[i - 1], b[j - 1]))
                table[(i - 1) * w + (j - 1)] + 1
            else
                @max(table[(i - 1) * w + j], table[i * w + (j - 1)]);
        }
    }

    var ops: std.ArrayList(Op) = .empty;
    var i = a.len;
    var j = b.len;

    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and same(loose, a[i - 1], b[j - 1])) {
            try ops.append(arena, .{ .kind = .equal, .text = a[i - 1], .new = b[j - 1] });
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or table[i * w + (j - 1)] >= table[(i - 1) * w + j])) {
            try ops.append(arena, .{ .kind = .ins, .text = b[j - 1] });
            j -= 1;
        } else {
            try ops.append(arena, .{ .kind = .del, .text = a[i - 1] });
            i -= 1;
        }
    }
    std.mem.reverse(Op, ops.items);
    return ops.toOwnedSlice(arena);
}

const testing = std.testing;

test "diff" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();
    try write(&buf.writer, "f.rv", "a\nb\nc\nd\n", "a\nB\nc\nd\n");
    try testing.expectEqualStrings(
        "--- f.rv\n+++ f.rv\n@@ -1,4 +1,4 @@\n a\n-b\n+B\n c\n d\n",
        buf.written(),
    );
}

test "edits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Want = struct { usize, usize, []const u8 };
    const cases = [_]struct { old: []const u8, new: []const u8, want: []const Want }{
        .{ .old = "a\nb\nc\nd\ne", .new = "a\nB\nc\nd\ne\nf\n", .want = &.{ .{ 2, 4, "B\n" }, .{ 8, 9, "e\n" }, .{ 9, 9, "f\n" } } },
        // a reindented line pairs with its old self, so each is its own edit
        .{ .old = "f do\nb\nc\nend\n", .new = "f do\n  b\n  c\nend\n", .want = &.{ .{ 5, 7, "  b\n" }, .{ 7, 9, "  c\n" } } },
        .{ .old = "a\n", .new = "a\n", .want = &.{} },
    };
    for (cases) |c| {
        const got = try edits(arena, c.old, c.new);
        try testing.expectEqual(c.want.len, got.len);
        for (c.want, got) |w, g| {
            try testing.expectEqual(.{ w[0], w[1] }, .{ g.start, g.end });
            try testing.expectEqualStrings(w[2], g.text);
        }
        try testing.expectEqualStrings(c.new, try apply(arena, c.old, got));
    }
}
