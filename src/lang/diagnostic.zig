const std = @import("std");

const ast = @import("./ast.zig");
const pretty = @import("../pretty.zig");

pub const Severity = enum { err, warning, note, help };

pub const SpanRole = enum { primary, secondary, context, trace };

pub const SpanPart = struct {
    span: ast.Span,
    role: SpanRole = .primary,
    message: []const u8 = "",
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

pub const Label = struct {
    span: ast.Span,
    message: []const u8 = "",
};

pub const Note = struct {
    message: []const u8,
};

pub const TraceFrame = struct {
    function_name: []const u8,
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    span: ?ast.Span = null,
    pc: ?usize = null,

    pub fn empty() TraceFrame {
        return .{ .function_name = "" };
    }
};

pub const Part = union(enum) {
    span: SpanPart,
    @"error": []const u8,
    tip: []const u8,
    warn: []const u8,
    note: []const u8,
    trace: TraceFrame,
};

pub const Report = struct {
    parts: []const Part = &.{},
    message: []const u8 = "",
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    owned_message: bool = false,
    owned_parts: bool = false,

    pub fn deinit(self: Report, alloc: std.mem.Allocator) void {
        if (self.owned_message and self.message.len != 0) alloc.free(self.message);
        if (self.owned_parts) alloc.free(self.parts);
    }
};

pub fn Diagnostic(comptime Kind: type) type {
    return struct {
        kind: Kind,
        report: Report,

        pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
            self.report.deinit(alloc);
        }
    };
}

pub fn primarySpan(report: Report) ?SpanPart {
    for (report.parts) |part| {
        switch (part) {
            .span => |span| if (span.role == .primary) return span,
            else => {},
        }
    }
    for (report.parts) |part| {
        switch (part) {
            .span => return part.span,
            else => {},
        }
    }
    return null;
}

pub fn firstError(report: Report) ?[]const u8 {
    for (report.parts) |part| {
        switch (part) {
            .@"error" => |msg| return msg,
            else => {},
        }
    }
    return null;
}

pub fn renderReport(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    report: Report,
) !void {
    const source_name = report.source_name orelse "<source>";
    const source = report.source orelse "";
    const header = if (report.message.len != 0) report.message else firstError(report);

    if (header) |message| {
        try pretty.printError(alloc, writer, "{s}", .{message});
    }

    var trace_seen = false;
    var trace_idx: usize = 0;
    for (report.parts) |part| {
        switch (part) {
            .@"error" => {},
            .span => |span| {
                try renderSpan(
                    writer,
                    span.source_name orelse source_name,
                    span.source orelse source,
                    span.span,
                    if (span.message.len == 0) null else span.message,
                );
            },
            .tip => |tip| try writer.print("  = tip: {s}\n", .{tip}),
            .warn => |warn| try writer.print("  = warning: {s}\n", .{warn}),
            .note => |note| try writer.print("  = note: {s}\n", .{note}),
            .trace => |frame| {
                if (!trace_seen) {
                    try writer.writeAll("\nstack trace:\n");
                    trace_seen = true;
                }
                try renderTrace(writer, frame, trace_idx);
                trace_idx += 1;
            },
        }
    }
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
    var parts = try std.ArrayList(Part).initCapacity(alloc, 8);

    try parts.append(alloc, Part{ .@"error" = message });
    if (span) |s| {
        try parts.append(alloc, .{ .span = .{ .span = s, .role = .primary, .source_name = source_name, .source = source } });
    }
    for (labels) |label| {
        try parts.append(alloc, .{ .span = .{
            .span = label.span,
            .role = .secondary,
            .message = label.message,
            .source_name = source_name,
            .source = source,
        } });
    }
    for (notes) |note| {
        try parts.append(alloc, .{ .note = note.message });
    }

    const owned_parts = try parts.toOwnedSlice(alloc);
    var report: Report = .{
        .message = message,
        .parts = owned_parts,
        .source_name = source_name,
        .source = source,
        .owned_parts = true,
    };
    defer report.deinit(alloc);
    try renderReport(alloc, writer, report);
}

fn renderTrace(writer: *std.Io.Writer, frame: TraceFrame, idx: usize) !void {
    const frame_source = frame.source_name orelse "<source>";
    try writer.print("  {d}: {s}", .{ idx, frame.function_name });
    if (frame.span) |span| {
        try writer.print(" at {s}:{d}:{d}", .{ frame_source, span.line, span.column });
    } else if (frame.pc) |pc| {
        try writer.print(" at {s}:pc={d}", .{ frame_source, pc });
    } else {
        try writer.print(" at {s}", .{frame_source});
    }
    try writer.writeByte('\n');
}

fn renderSpan(
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    location: ast.Span,
    label_message: ?[]const u8,
) !void {
    const line = if (location.line == 0) 1 else location.line;
    const column = if (location.column == 0) 1 else location.column;

    const line_start_pos = std.mem.lastIndexOfScalar(u8, source[0..@min(location.start, source.len)], '\n') orelse 0;
    const line_start = if (line_start_pos == 0) 0 else line_start_pos + 1;
    const end_rel = std.mem.indexOfScalar(u8, source[line_start..], '\n') orelse source.len - line_start;
    const line_text = source[line_start .. line_start + end_rel];
    const span_len = @min(location.end -| location.start, line_text.len -| (column - 1));
    const highlight_len = @max(span_len, 1);

    try writer.print(" --> {s}:{d}:{d}\n", .{ source_name, line, column });
    try writer.writeAll("   |\n");
    try writer.print("{d: >2} | {s}\n", .{ line, line_text });
    try writer.writeAll("   | ");
    for (1..column) |_| try writer.writeByte(' ');
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
