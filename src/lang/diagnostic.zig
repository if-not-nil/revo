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

    pub fn deinitOwned(report: Report, alloc: std.mem.Allocator) void {
        if (report.owned_message and report.message.len != 0) alloc.free(report.message);

        if (report.owned_parts) {
            for (report.parts) |part| {
                switch (part) {
                    .@"error" => {},
                    .tip => |tip| alloc.free(tip),
                    .warn => |warn| alloc.free(warn),
                    .note => |note| alloc.free(note),
                    .span => |span| {
                        if (span.message.len != 0) alloc.free(span.message);
                        if (span.source_name) |source_name| alloc.free(source_name);
                        if (span.source) |source| alloc.free(source);
                    },
                    .trace => |frame| {
                        alloc.free(frame.function_name);
                        if (frame.source_name) |source_name| alloc.free(source_name);
                        if (frame.source) |source| alloc.free(source);
                    },
                }
            }
            alloc.free(report.parts);
        }
    }

    pub fn copy(
        report: Report,
        alloc: std.mem.Allocator,
    ) !Report {
        const message = try alloc.dupe(u8, report.message);
        errdefer alloc.free(message);
        const parts = try alloc.dupe(Part, report.parts);
        errdefer alloc.free(parts);

        for (parts) |*part| switch (part.*) {
            .@"error" => part.* = .{ .@"error" = message },
            .tip => |tip| part.* = .{ .tip = try alloc.dupe(u8, tip) },
            .warn => |warn| part.* = .{ .warn = try alloc.dupe(u8, warn) },
            .note => |note| part.* = .{ .note = try alloc.dupe(u8, note) },
            .span => |span| {
                var copied = span;
                if (copied.message.len != 0) copied.message = try alloc.dupe(u8, copied.message);
                if (copied.source_name) |source_name| copied.source_name = try alloc.dupe(u8, source_name);
                if (copied.source) |source| copied.source = try alloc.dupe(u8, source);
                part.* = .{ .span = copied };
            },
            .trace => |frame| {
                var copied = frame;
                copied.function_name = try alloc.dupe(u8, copied.function_name);
                if (copied.source_name) |source_name| copied.source_name = try alloc.dupe(u8, source_name);
                if (copied.source) |source| copied.source = try alloc.dupe(u8, source);
                part.* = .{ .trace = copied };
            },
        };

        return .{
            .parts = parts,
            .message = message,
            .source_name = null,
            .source = null,
            .owned_message = true,
            .owned_parts = true,
        };
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
    const start_line = if (location.line == 0) 1 else location.line;
    const start_column = if (location.column == 0) 1 else location.column;

    try writer.print(" --> {s}:{d}:{d}\n", .{ source_name, start_line, start_column });
    try writer.writeAll("   |\n");

    const clamped_start = @min(location.start, source.len);
    const line1_before = std.mem.findScalarLast(u8, source[0..clamped_start], '\n') orelse 0;
    var line_byte: usize = if (line1_before == 0) 0 else line1_before + 1;
    var line_num: u32 = start_line;

    while (line_byte < location.end and line_byte < source.len) {
        const line_end_rel = std.mem.findScalar(u8, source[line_byte..], '\n') orelse (source.len - line_byte);
        const line_end = line_byte + line_end_rel;
        const line_text = source[line_byte..line_end];

        const span_start_here = if (line_num == start_line) location.start else line_byte;
        const span_end_here = @min(location.end, line_end);
        const span_here = span_end_here -| span_start_here;
        const col = if (line_num == start_line) start_column else 1;
        const clamped = @min(span_here, line_text.len -| (col - 1));
        const highlight = @max(clamped, 1);

        try writer.print("{d: >2} | {s}\n", .{ line_num, line_text });
        try writer.writeAll("   | ");
        for (1..col) |_| try writer.writeByte(' ');
        if (line_num == start_line and line_end >= location.end) {
            try writer.writeByte('^');
            if (highlight > 1) {
                for (0..highlight - 2) |_| try writer.writeByte('~');
                try writer.writeByte('^');
            }
            if (label_message) |msg| try writer.print(" {s}", .{msg});
        } else if (line_num == start_line) {
            try writer.writeByte('^');
            if (highlight > 1) for (0..highlight - 1) |_| try writer.writeByte('~');
        } else if (line_end >= location.end) {
            if (highlight > 1) {
                for (0..highlight - 1) |_| try writer.writeByte('~');
            }
            try writer.writeByte('^');
            if (label_message) |msg| try writer.print(" {s}", .{msg});
        } else {
            for (0..highlight) |_| try writer.writeByte('~');
        }
        try writer.writeByte('\n');

        line_byte = line_end + 1;
        line_num += 1;
    }
}

test "single line span" {
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

test "multi-line span" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try renderAt(
        std.testing.allocator,
        &buf.writer,
        "multi.rv",
        \\let x = (1,
        \\  2,
        \\  3)
        \\
    ,
        .{ .start = 8, .end = 20, .line = 1, .column = 9 },
        "type mismatch",
        &.{},
        &.{},
    );
    const output = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " 1 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " 2 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " 3 |") != null);
}
