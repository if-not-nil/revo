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
};

/// write `old` -> `new` as a diff, `name` is the path
pub fn write(out: *std.Io.Writer, name: []const u8, old: []const u8, new: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try out.print("--- {s}\n+++ {s}\n", .{ name, name });
    try hunks(out, try script(arena, try split(arena, old, false), try split(arena, new, false)), 1);
}

/// `old[start..end]` becomes `text`, a slice of `new`
pub const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

/// the changed runs of lines that turn `old` into `new`, in order and
/// apart, for an editor that should keep its cursor and undo history
pub fn edits(arena: std.mem.Allocator, old: []const u8, new: []const u8) ![]const Edit {
    // lines keep their `\n`, so a missing last newline is a change too
    const ops = try script(arena, try split(arena, old, true), try split(arena, new, true));
    var out: std.ArrayList(Edit) = .empty;
    var at: usize = 0;
    var new_at: usize = 0;
    var i: usize = 0;
    while (i < ops.len) {
        if (ops[i].kind == .equal) {
            at += ops[i].text.len;
            new_at += ops[i].text.len;
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

/// every line of `a` and `b` as equal, deleted or inserted
fn script(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]const Op {
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and std.mem.eql(u8, a[pre], b[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and
        std.mem.eql(u8, a[a.len - 1 - suf], b[b.len - 1 - suf])) suf += 1;
    const mid_a = a[pre .. a.len - suf];
    const mid_b = b[pre .. b.len - suf];

    var ops: std.ArrayList(Op) = .empty;
    for (a[0..pre]) |line| try ops.append(arena, .{ .kind = .equal, .text = line });
    // a full reformat:
    //   every line differs, no table needed
    if (mid_a.len * mid_b.len > max_cells) {
        for (mid_a) |line| try ops.append(arena, .{ .kind = .del, .text = line });
        for (mid_b) |line| try ops.append(arena, .{ .kind = .ins, .text = line });
    } else try ops.appendSlice(arena, try lcs(arena, mid_a, mid_b));
    for (a[a.len - suf ..]) |line| try ops.append(arena, .{ .kind = .equal, .text = line });
    return ops.items;
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
fn lcs(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]const Op {
    // i have no idea what this function does anymore
    const w = b.len + 1;
    const table = try arena.alloc(u32, (a.len + 1) * w);

    @memset(table, 0);
    for (1..a.len + 1) |i| {
        for (1..b.len + 1) |j| {
            table[i * w + j] = if (std.mem.eql(u8, a[i - 1], b[j - 1]))
                table[(i - 1) * w + (j - 1)] + 1
            else
                @max(table[(i - 1) * w + j], table[i * w + (j - 1)]);
        }
    }

    var ops: std.ArrayList(Op) = .empty;
    var i = a.len;
    var j = b.len;

    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, a[i - 1], b[j - 1])) {
            try ops.append(arena, .{ .kind = .equal, .text = a[i - 1] });
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

    const old = "a\nb\nc\nd\ne";
    const new = "a\nB\nc\nd\ne\nf\n";
    const got = try edits(arena, old, new);
    try testing.expectEqual(2, got.len);
    try testing.expectEqual(.{ 2, 4 }, .{ got[0].start, got[0].end });
    try testing.expectEqualStrings("B\n", got[0].text);
    try testing.expectEqual(.{ 8, 9 }, .{ got[1].start, got[1].end });
    try testing.expectEqualStrings("e\nf\n", got[1].text);

    // applied back to front, they rebuild `new`
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, old);
    var i = got.len;
    while (i > 0) {
        i -= 1;
        try buf.replaceRange(arena, got[i].start, got[i].end - got[i].start, got[i].text);
    }
    try testing.expectEqualStrings(new, buf.items);

    try testing.expectEqual(0, (try edits(arena, old, old)).len);
}
