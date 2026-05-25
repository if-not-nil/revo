const std = @import("std");

const ast = @import("./ast.zig");
const pretty = @import("../pretty.zig");

pub const Severity = enum { err, warning, note, help };

pub const Label = struct {
    span: ast.Span,
    message: []const u8 = "",
};

pub const Note = struct {
    message: []const u8,
};

pub fn Diagnostic(comptime Kind: type) type {
    return struct {
        kind: Kind,
        span: ast.Span,
        message: []const u8,
        labels: []const Label = &.{},
        notes: []const Note = &.{},
        source_name: ?[]const u8 = null,
        owned: bool = false,

        pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
            if (self.owned) alloc.free(self.message);
        }
    };
}

pub fn renderAt(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    span: ?ast.Span,
    message: []const u8,
    labels: []const Label,
    notes: []const Note,
) !void {
    try pretty.printError(alloc, writer, "{s}", .{message});

    const primary = span orelse return;
    try renderSpan(writer, source_name, source, primary, null);
    for (labels) |label| {
        try renderSpan(writer, source_name, source, label.span, if (label.message.len == 0) null else label.message);
    }
    for (notes) |note| {
        try writer.print("  = note: {s}\n", .{note.message});
    }
}

fn renderSpan(
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    location: ast.Span,
    label_message: ?[]const u8,
) !void {
    var line: usize = 1;
    var column: usize = 1;
    var i: usize = 0;
    while (i < @min(location.start, source.len)) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }

    const line_start_pos = std.mem.lastIndexOfScalar(u8, source[0..@min(location.start, source.len)], '\n') orelse 0;
    const line_start = if (line_start_pos == 0) 0 else line_start_pos + 1;
    const end_rel = std.mem.indexOfScalar(u8, source[line_start..], '\n') orelse source.len - line_start;
    const line_text = source[line_start .. line_start + end_rel];
    const caret_col = if (column == 0) @as(usize, 1) else column;
    const span_len = @min(location.end -| location.start, line_text.len -| (caret_col - 1));
    const highlight_len = @max(span_len, 1);

    try writer.print(" --> {s}:{d}:{d}\n", .{ source_name, line, column });
    try writer.writeAll("   |\n");
    try writer.print("{d: >2} | {s}\n", .{ line, line_text });
    try writer.writeAll("   | ");
    for (1..caret_col) |_| try writer.writeByte(' ');
    try writer.writeByte('^');
    if (highlight_len > 1) {
        for (0..highlight_len - 2) |_| try writer.writeByte('~');
        try writer.writeByte('^');
    }
    if (label_message) |msg| {
        try writer.print(" {s}", .{msg});
    }
    try writer.writeByte('\n');
}

test "diagnostics: render right" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try renderAt(
        std.testing.allocator,
        &buf.writer,
        "example.rv",
        "let x = 1\nlet y = 2\n",
        .{ .start = 4, .end = 5, .line = 1, .column = 5 },
        "boom",
        &.{.{ .span = .{ .start = 14, .end = 15, .line = 2, .column = 5 }, .message = "here" }},
        &.{.{ .message = "try something else" }},
    );
    try std.testing.expect(buf.written().len != 0);
}
