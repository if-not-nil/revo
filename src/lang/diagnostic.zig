// diagnostics borrow their text and source slices from arena-backed storage
// do not manually free anything

const std = @import("std");

const ast = @import("./ast.zig");
const pretty = @import("../pretty.zig");

/// severity bucket for a diagnostic report
/// TODO: only err and warning can be toggled
pub const Severity = enum { err, warning, note, help };

/// role for a span inside a report
/// TODO: only context can be toggled off
pub const SpanRole = enum { primary, secondary, context, trace };

// TODO: decide on colors for box and each bucket
const COLOR_DIM = "\x1b[2m";
const COLOR_RESET = "\x1b[0m";

/// one span entry attached to a report
pub const SpanPart = struct {
    span: ast.Span,
    role: SpanRole = .primary,
    message: []const u8 = "",
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

/// label tied to a span
pub const Label = struct {
    span: ast.Span,
    message: []const u8 = "",
};

/// plain note line
pub const Note = struct {
    message: []const u8,
};

/// stack trace frame with optional source context
pub const TraceFrame = struct {
    function_name: []const u8,
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    span: ?ast.Span = null,
    pc: ?usize = null,

    /// empty frame shell
    pub fn empty() TraceFrame {
        return .{ .function_name = "" };
    }
};

/// one rendered part of a report
pub const Part = union(enum) {
    span: SpanPart,
    @"error": []const u8,
    tip: []const u8,
    warn: []const u8,
    note: []const u8,
    trace: TraceFrame,
};

/// arena-backed payload
pub const Report = struct {
    parts: []const Part = &.{},
    message: []const u8 = "",
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,

    pub fn deinit(self: *Report, alloc: std.mem.Allocator) void {
        if (self.message.len != 0) alloc.free(self.message);
        if (self.source_name) |source_name| alloc.free(source_name);
        if (self.source) |source| alloc.free(source);
        for (self.parts) |part| switch (part) {
            .@"error" => |err| alloc.free(err),
            .tip => |tip| alloc.free(tip),
            .warn => |warn| alloc.free(warn),
            .note => |note| alloc.free(note),
            .span => |span| {
                if (span.message.len != 0) alloc.free(span.message);
                if (span.source_name) |source_name| alloc.free(source_name);
                if (span.source) |source| alloc.free(source);
            },
            .trace => |trace| {
                alloc.free(trace.function_name);
                if (trace.source_name) |source_name| alloc.free(source_name);
                if (trace.source) |source| alloc.free(source);
            },
        };
        alloc.free(self.parts);
    }

    /// deep copy borrowed text into `alloc`
    pub fn copy(
        report: Report,
        alloc: std.mem.Allocator,
    ) !Report {
        const message = try alloc.dupe(u8, report.message);
        errdefer alloc.free(message);
        const parts = try alloc.dupe(Part, report.parts);
        errdefer alloc.free(parts);

        for (parts) |*part| switch (part.*) {
            .@"error" => |err| part.* = .{ .@"error" = try alloc.dupe(u8, err) },
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
        };
    }
};

/// wrapper for reports emitted by a phase
pub fn Diagnostic(comptime Kind: type) type {
    return struct {
        kind: Kind,
        report: Report,
    };
}

/// primary span if the report has one
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

/// first error message if the report has one
pub fn firstError(report: Report) ?[]const u8 {
    for (report.parts) |part| {
        switch (part) {
            .@"error" => |msg| return msg,
            else => {},
        }
    }
    return null;
}

/// render a full report to the writer
pub fn renderReport(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    report: Report,
) !void {
    const source_name = report.source_name orelse "<source>";
    const source = report.source orelse "";
    if (report.parts.len == 0 and report.message.len != 0) {
        try pretty.printError(writer, "{s}", .{report.message});
        return;
    }

    var error_seen = false;
    var trace_seen = false;
    var trace_idx: usize = 0;
    for (report.parts) |part| {
        switch (part) {
            .@"error" => |message| {
                if (error_seen) try writer.writeByte('\n');
                try pretty.printError(writer, "{s}", .{message});
                error_seen = true;
            },
            .span => |span| switch (span.role) {
                .primary => try renderSpanBlock(
                    alloc,
                    writer,
                    span.source_name orelse source_name,
                    span.source orelse source,
                    span.span,
                    if (span.message.len == 0) null else span.message,
                ),
                .secondary => try renderSecondarySpan(
                    writer,
                    span.source_name orelse source_name,
                    span.span,
                    if (span.message.len == 0) null else span.message,
                ),
                else => {},
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

/// render ad hoc report from span and labels
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
    const part_count = 1 + @as(usize, @intFromBool(span != null)) + labels.len + notes.len;
    var parts = try alloc.alloc(Part, part_count);
    defer alloc.free(parts);

    var part_index: usize = 0;
    parts[part_index] = .{ .@"error" = message };
    part_index += 1;
    if (span) |s| {
        parts[part_index] = .{ .span = .{ .span = s, .role = .primary, .source_name = source_name, .source = source } };
        part_index += 1;
    }
    for (labels) |label| {
        parts[part_index] = .{ .span = .{
            .span = label.span,
            .role = .secondary,
            .message = label.message,
            .source_name = source_name,
            .source = source,
        } };
        part_index += 1;
    }
    for (notes) |note| {
        parts[part_index] = .{ .note = note.message };
        part_index += 1;
    }

    const report: Report = .{
        .message = message,
        .parts = parts,
        .source_name = source_name,
        .source = source,
    };
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

const SpanLine = struct {
    num: u32,
    text: []const u8,
    span_start: usize,
    span_end: usize,
    span_col: u32,
};

// not good: renderSpanBlock and renderBoxSpanBlock share ~80% of their
// context-extraction and bookend logic but are separate codepaths
fn countDigits(value: u32) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits;
}

fn leadingWhitespaceLen(text: []const u8) usize {
    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        const ch = text[idx];
        if (ch != ' ' and ch != '\t') break;
    }
    return idx;
}

fn writeLineNumber(writer: *std.Io.Writer, num: u32, width: usize) !void {
    const digits = countDigits(num);
    if (width > digits) {
        for (0..width - digits) |_| try writer.writeByte(' ');
    }
    try writer.print("{d}", .{num});
    try writePipePrefix(writer, 2);
}

fn writeDimStart(writer: *std.Io.Writer) !void {
    if (pretty.supports_color) try writer.writeAll(COLOR_DIM);
}

fn writeDimEnd(writer: *std.Io.Writer) !void {
    if (pretty.supports_color) try writer.writeAll(COLOR_RESET);
}

fn writeBlankLineNumber(writer: *std.Io.Writer, width: usize) !void {
    for (0..width) |_| try writer.writeByte(' ');
}

fn writePipePrefix(writer: *std.Io.Writer, spaces_after_pipe: usize) !void {
    try writer.writeByte(' ');
    try writer.writeByte('|');
    for (0..spaces_after_pipe) |_| try writer.writeByte(' ');
}

fn writeBoxPrefix(writer: *std.Io.Writer, line_width: usize, indent: usize) !void {
    try writeBlankLineNumber(writer, line_width);
    try writePipePrefix(writer, indent);
}

fn writeBlankPipeLine(writer: *std.Io.Writer, line_width: usize, indent: usize) !void {
    try writeBoxPrefix(writer, line_width, indent);
    try writer.writeByte('\n');
}

fn countSpanLines(source: []const u8, start: usize, end: usize) usize {
    const lo = @min(start, source.len);
    const hi = @min(end, source.len);
    var lines: usize = 1;
    for (source[lo..hi]) |ch| {
        if (ch == '\n') lines += 1;
    }
    return lines;
}

fn renderSecondarySpan(
    writer: *std.Io.Writer,
    source_name: []const u8,
    location: ast.Span,
    label_message: ?[]const u8,
) !void {
    const line = if (location.line == 0) 1 else location.line;
    const column = if (location.column == 0) 1 else location.column;
    try writer.print("  = {s}\n", .{label_message orelse "secondary span"});
    try writer.print("    --> {s}:{d}:{d}\n", .{ source_name, line, column });
}

fn renderSpanBlock(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    location: ast.Span,
    label_message: ?[]const u8,
) !void {
    const start_line = if (location.line == 0) 1 else location.line;
    const start_column = if (location.column == 0) 1 else location.column;
    const span_lines = countSpanLines(source, location.start, location.end);

    if (span_lines > 1) {
        try renderBoxSpanBlock(
            alloc,
            writer,
            source_name,
            source,
            location,
            label_message,
            start_line,
            start_column,
        );
        return;
    }

    try writer.print(" --> {s}:{d}:{d}\n", .{ source_name, start_line, start_column });

    const clamped_start = @min(location.start, source.len);
    const line1_before = std.mem.findScalarLast(u8, source[0..clamped_start], '\n') orelse 0;
    var line_byte: usize = if (line1_before == 0) 0 else line1_before + 1;
    var line_num: u32 = start_line;
    const line_cap = countSpanLines(source, location.start, location.end);
    const render_end = if (location.end <= line_byte) @min(line_byte + 1, source.len) else location.end;

    var lines = try alloc.alloc(SpanLine, line_cap);
    defer alloc.free(lines);
    var total: usize = 0;

    while (line_byte < render_end and line_byte < source.len) {
        const line_end_rel = std.mem.findScalar(u8, source[line_byte..], '\n') orelse (source.len - line_byte);
        const line_end = line_byte + line_end_rel;
        lines[total] = .{
            .num = line_num,
            .text = source[line_byte..line_end],
            .span_start = if (line_num == start_line) location.start else line_byte,
            .span_end = @min(render_end, line_end),
            .span_col = if (line_num == start_line) start_column else 1,
        };
        total += 1;
        line_byte = line_end + 1;
        line_num += 1;
    }
    if (total == 0) return;
    const lines_view = lines[0..total];
    var ctx_before: [2]SpanLine = undefined;
    var ctx_before_len: usize = 0;

    if (total > 0 and line1_before > 0) {
        var prev_end: usize = line1_before;
        var ctx_num: u32 = start_line;
        while (ctx_before_len < 2 and prev_end > 0) {
            const prev_nl = std.mem.findScalarLast(u8, source[0..prev_end], '\n') orelse 0;
            const ctx_start = if (prev_nl == 0) 0 else prev_nl + 1;
            const ctx_text = source[ctx_start..prev_end];
            if (ctx_num == 0) break;
            ctx_num -= 1;
            if (std.mem.trim(u8, ctx_text, " \t\r").len != 0) {
                ctx_before[ctx_before_len] = .{
                    .num = ctx_num,
                    .text = ctx_text,
                    .span_start = 0,
                    .span_end = 0,
                    .span_col = 0,
                };
                ctx_before_len += 1;
            }
            prev_end = prev_nl;
        }
    }

    var ctx_after: [2]SpanLine = undefined;
    var ctx_after_len: usize = 0;

    if (total > 0) {
        var ctx_pos: usize = line_byte;
        var ctx_num: u32 = line_num;
        while (ctx_after_len < 2) {
            if (ctx_pos >= source.len) break;
            const next_nl = std.mem.findScalar(u8, source[ctx_pos..], '\n') orelse (source.len - ctx_pos);
            const ctx_text = source[ctx_pos .. ctx_pos + next_nl];
            const trimmed = std.mem.trim(u8, ctx_text, " \t\r");
            if (trimmed.len == 0) {
                ctx_pos = ctx_pos + next_nl + 1;
                ctx_num += 1;
                continue;
            }
            ctx_after[ctx_after_len] = .{
                .num = ctx_num,
                .text = ctx_text,
                .span_start = 0,
                .span_end = 0,
                .span_col = 0,
            };
            ctx_after_len += 1;
            ctx_pos = ctx_pos + next_nl + 1;
            ctx_num += 1;
            if (ctx_pos >= source.len) break;
        }
    }

    const max_line_num = blk: {
        var max_line: u32 = start_line;
        for (ctx_before[0..ctx_before_len]) |cl| {
            if (cl.num > max_line) max_line = cl.num;
        }
        for (lines_view) |cl| {
            if (cl.num > max_line) max_line = cl.num;
        }
        for (ctx_after[0..ctx_after_len]) |cl| {
            if (cl.num > max_line) max_line = cl.num;
        }
        break :blk max_line;
    };
    const line_width = @max(countDigits(max_line_num), @as(usize, 2));

    // render ctx before: plain lines above the span
    var before_idx: usize = ctx_before_len;
    while (before_idx > 0) {
        before_idx -= 1;
        const cl = ctx_before[before_idx];
        try writeLineNumber(writer, cl.num, line_width);
        try writer.writeAll(cl.text);
        try writer.writeByte('\n');
    }
    if (ctx_before_len > 0) {
        try writeBlankPipeLine(writer, line_width, 0);
    }

    // render span lines: the source block itself and its edge markers
    const bookend_threshold = 10;
    const tail_cut = if (total > bookend_threshold) 5 else total;
    const tail_start = if (total > bookend_threshold and total >= 10) total - 5 else total;
    var bookend_printed = false;

    for (lines_view, 0..) |cl, i| {
        const is_first = i == 0;
        const is_last = i + 1 == total;
        const in_head = i < tail_cut;
        const in_tail = i >= tail_start;

        // bookend
        if (total > bookend_threshold and !in_head and !in_tail) {
            if (!bookend_printed) {
                try writer.print("   ... {d} lines ...\n", .{total - tail_cut - (total - tail_start)});
                bookend_printed = true;
            }
            continue;
        }

        // this is the actual code row in the box
        try writeLineNumber(writer, cl.num, line_width);
        // try writer.writeAll(source_bracket);
        try writer.writeAll(cl.text);
        try writer.writeByte('\n');

        // underline marker: only the first and last rows get it
        if (is_first or is_last or (is_first and is_last)) {
            const col = cl.span_col;
            const span_here = cl.span_end -| cl.span_start;
            const clamped = @min(span_here, cl.text.len -| (col - 1));
            const highlight = @max(clamped, 1);
            const pad = if (col > 1) col - 1 else 0;
            const ul_bracket_spaces: usize = if (is_first and is_last) 2 else if (is_last) 2 else 2;
            try writeBlankLineNumber(writer, line_width);
            try writer.writeByte(' ');
            try writer.writeByte('|');
            for (0..ul_bracket_spaces) |_| try writer.writeByte(' ');
            for (0..pad) |_| try writer.writeByte(' ');
            if (is_first and is_last) {
                try writer.writeByte('^');
                if (highlight > 1) {
                    for (0..highlight - 2) |_| try writer.writeByte('~');
                    try writer.writeByte('^');
                }
                if (label_message) |msg| try writer.print(" {s}", .{msg});
            } else if (is_first) {
                try writer.writeByte('^');
                if (highlight > 1) for (0..highlight - 1) |_| try writer.writeByte('~');
            } else if (is_last) {
                if (highlight > 1) {
                    for (0..highlight - 1) |_| try writer.writeByte('~');
                }
                try writer.writeByte('^');
                if (label_message) |msg| try writer.print(" {s}", .{msg});
            }
            try writer.writeByte('\n');
        }
    }

    // render ctx after: plain lines below the span
    if (ctx_after_len > 0) {
        try writeBlankPipeLine(writer, line_width, 0);
    }
    for (ctx_after[0..ctx_after_len]) |cl| {
        try writeLineNumber(writer, cl.num, line_width);
        try writer.writeAll(cl.text);
        try writer.writeByte('\n');
    }
}

fn renderBoxSpanBlock(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    location: ast.Span,
    label_message: ?[]const u8,
    start_line: u32,
    start_column: u32,
) !void {
    try writer.print(" --> {s}:{d}:{d}\n", .{ source_name, start_line, start_column });
    try writeDimStart(writer);
    try writePipePrefix(writer, 0);
    try writer.writeByte('\n');
    try writeDimEnd(writer);

    const clamped_start = @min(location.start, source.len);
    const line1_before = std.mem.findScalarLast(u8, source[0..clamped_start], '\n') orelse 0;
    var line_byte: usize = if (line1_before == 0) 0 else line1_before + 1;
    var line_num: u32 = start_line;
    const line_cap = countSpanLines(source, location.start, location.end);
    const render_end = if (location.end <= line_byte) @min(line_byte + 1, source.len) else location.end;

    var lines = try alloc.alloc(SpanLine, line_cap);
    defer alloc.free(lines);
    var total: usize = 0;
    while (line_byte < render_end and line_byte < source.len) {
        const line_end_rel = std.mem.findScalar(u8, source[line_byte..], '\n') orelse (source.len - line_byte);
        const line_end = line_byte + line_end_rel;
        lines[total] = .{
            .num = line_num,
            .text = source[line_byte..line_end],
            .span_start = if (line_num == start_line) location.start else line_byte,
            .span_end = @min(render_end, line_end),
            .span_col = if (line_num == start_line) start_column else 1,
        };
        total += 1;
        line_byte = line_end + 1;
        line_num += 1;
    }
    if (total == 0) return;
    const lines_view = lines[0..total];

    var ctx_before: [2]SpanLine = undefined;
    var ctx_before_len: usize = 0;
    if (total > 0 and line1_before > 0) {
        var prev_end: usize = line1_before;
        var ctx_num: u32 = start_line;
        while (ctx_before_len < 2 and prev_end > 0) {
            const prev_nl = std.mem.findScalarLast(u8, source[0..prev_end], '\n') orelse 0;
            const ctx_start = if (prev_nl == 0) 0 else prev_nl + 1;
            const ctx_text = source[ctx_start..prev_end];
            if (ctx_num == 0) break;
            ctx_num -= 1;
            if (std.mem.trim(u8, ctx_text, " \t\r").len != 0) {
                ctx_before[ctx_before_len] = .{
                    .num = ctx_num,
                    .text = ctx_text,
                    .span_start = 0,
                    .span_end = 0,
                    .span_col = 0,
                };
                ctx_before_len += 1;
            }
            prev_end = prev_nl;
        }
    }

    var ctx_after: [2]SpanLine = undefined;
    var ctx_after_len: usize = 0;
    if (total > 0) {
        var ctx_pos: usize = line_byte;
        var ctx_num: u32 = line_num;
        while (ctx_after_len < 2) {
            if (ctx_pos >= source.len) break;
            const next_nl = std.mem.findScalar(u8, source[ctx_pos..], '\n') orelse (source.len - ctx_pos);
            const ctx_text = source[ctx_pos .. ctx_pos + next_nl];
            const trimmed = std.mem.trim(u8, ctx_text, " \t\r");
            if (trimmed.len == 0) {
                ctx_pos = ctx_pos + next_nl + 1;
                ctx_num += 1;
                continue;
            }
            ctx_after[ctx_after_len] = .{
                .num = ctx_num,
                .text = ctx_text,
                .span_start = 0,
                .span_end = 0,
                .span_col = 0,
            };
            ctx_after_len += 1;
            ctx_pos = ctx_pos + next_nl + 1;
            ctx_num += 1;
            if (ctx_pos >= source.len) break;
        }
    }

    const max_line_num = blk: {
        var max_line: u32 = start_line;
        for (ctx_before[0..ctx_before_len]) |cl| {
            if (cl.num > max_line) max_line = cl.num;
        }
        for (lines_view) |cl| {
            if (cl.num > max_line) max_line = cl.num;
        }
        for (ctx_after[0..ctx_after_len]) |cl| {
            if (cl.num > max_line) max_line = cl.num;
        }
        break :blk max_line;
    };
    const line_width = @max(countDigits(max_line_num), @as(usize, 2));

    var before_idx: usize = ctx_before_len;
    while (before_idx > 0) {
        before_idx -= 1;
        const cl = ctx_before[before_idx];
        try writeDimStart(writer);
        try writeLineNumber(writer, cl.num, line_width);
        try writer.writeAll(cl.text);
        try writer.writeByte('\n');
        try writeDimEnd(writer);
    }
    if (ctx_before_len > 0) {
        try writeBlankPipeLine(writer, line_width, 0);
    }

    const bookend_threshold = 10;
    const tail_cut = if (total > bookend_threshold) 5 else total;
    const tail_start = if (total > bookend_threshold and total >= 10) total - 5 else total;
    var bookend_printed = false;

    const common_indent = blk: {
        var min_indent: usize = std.math.maxInt(usize);
        for (lines_view) |cl| {
            if (std.mem.trim(u8, cl.text, " \t\r").len == 0) continue;
            // shared indent: keep the box anchored to the source block
            const indent = leadingWhitespaceLen(cl.text);
            if (indent < min_indent) min_indent = indent;
        }
        break :blk if (min_indent == std.math.maxInt(usize)) 0 else min_indent;
    };
    const display_trim = common_indent;

    const first_line = lines_view[0];
    const last_line = lines_view[lines_view.len - 1];
    // gutter already takes two spaces, so offset from that baseline
    const box_offset = display_trim -| 4;
    // marker rows sit one column further left than code rows
    const marker_offset = display_trim -| 5;
    const top_dashes = @max(@as(usize, 1), first_line.span_col -| display_trim);
    const top_vs = @max(
        @as(usize, 1),
        (first_line.text.len -| display_trim) - (top_dashes - 1),
    );
    const bottom_dashes = @max(@as(usize, 1), (last_line.span_end -| last_line.span_start) -| display_trim);
    // top edge: box header and caret stem
    try writeBoxPrefix(writer, line_width, 3);
    for (0..marker_offset) |_| try writer.writeByte(' ');
    try writer.writeByte('+');
    for (0..top_dashes) |_| try writer.writeByte('-');
    for (0..top_vs) |_| try writer.writeByte('v');
    try writer.writeByte('\n');

    for (lines_view, 0..) |cl, i| {
        const in_head = i < tail_cut;
        const in_tail = i >= tail_start;
        if (total > bookend_threshold and !in_head and !in_tail) {
            if (!bookend_printed) {
                // middle collapse: dimmed summary for skipped rows
                try writeDimStart(writer);
                try writeBoxPrefix(writer, line_width, 3);
                for (0..marker_offset) |_| try writer.writeByte(' ');
                try writer.writeAll("...");
                try writer.print(" {d} lines ", .{total - tail_cut - (total - tail_start)});
                try writer.writeAll("...");
                try writer.writeByte('\n');
                try writeDimEnd(writer);
                bookend_printed = true;
            }
            continue;
        }
        // source row: keep the original indent inside the box
        try writeLineNumber(writer, cl.num, line_width);
        for (0..box_offset) |_| try writer.writeByte(' ');
        try writer.writeAll("| ");
        try writer.writeAll(cl.text[display_trim..]);
        try writer.writeByte('\n');
    }

    // bottom edge: close the box under the final source row
    try writeBoxPrefix(writer, line_width, 3);
    for (0..marker_offset) |_| try writer.writeByte(' ');
    try writer.writeByte('+');
    for (0..bottom_dashes) |_| try writer.writeByte('-');
    try writer.writeByte('^');
    if (label_message) |msg| try writer.print(" {s}", .{msg});
    try writer.writeByte('\n');

    if (ctx_after_len > 0) {
        try writeBlankPipeLine(writer, line_width, 0);
    }
    for (ctx_after[0..ctx_after_len]) |cl| {
        try writeDimStart(writer);
        try writeLineNumber(writer, cl.num, line_width);
        try writer.writeAll(cl.text);
        try writer.writeByte('\n');
        try writeDimEnd(writer);
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
    const output = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "let y = 2") != null);
}

test "multi-line span with bracket" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try renderAt(
        std.testing.allocator,
        &buf.writer,
        "multi.rv",
        \\before
        \\const x: string = 1 +
        \\  2 +
        \\  3
        \\after
    ,
        .{ .start = 14, .end = 36, .line = 2, .column = 18 },
        "x wants string, got int",
        &.{},
        &.{},
    );
    const output = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const x: string = 1 +") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "|   2 +") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "|   3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+-^") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "x wants string, got int") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "after") != null);
}

test "report copy preserves multiple error parts" {
    const alloc = std.testing.allocator;
    const report: Report = .{
        .message = "first problem",
        .parts = &.{
            .{ .@"error" = "first problem" },
            .{ .@"error" = "second problem" },
            .{ .span = .{
                .span = .{ .start = 0, .end = 1, .line = 1, .column = 1 },
                .role = .primary,
            } },
        },
    };

    const copied = try report.copy(alloc);
    defer {
        alloc.free(copied.message);
        for (copied.parts) |part| switch (part) {
            .@"error" => |msg| alloc.free(msg),
            .span => |span| {
                if (span.message.len != 0) alloc.free(span.message);
                if (span.source_name) |source_name| alloc.free(source_name);
                if (span.source) |source| alloc.free(source);
            },
            .tip => |tip| alloc.free(tip),
            .warn => |warn| alloc.free(warn),
            .note => |note| alloc.free(note),
            .trace => |trace| {
                alloc.free(trace.function_name);
                if (trace.source_name) |source_name| alloc.free(source_name);
                if (trace.source) |source| alloc.free(source);
            },
        };
        alloc.free(copied.parts);
    }

    try std.testing.expectEqualStrings("first problem", copied.message);
    try std.testing.expectEqualStrings("first problem", copied.parts[0].@"error");
    try std.testing.expectEqualStrings("second problem", copied.parts[1].@"error");
}

test "render report prints multiple error blocks" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const report: Report = .{
        .source_name = "<source>",
        .source = "hi\n",
        .parts = &.{
            .{ .@"error" = "first problem" },
            .{ .span = .{
                .span = .{ .start = 0, .end = 2, .line = 1, .column = 1 },
                .role = .primary,
            } },
            .{ .@"error" = "second problem" },
            .{ .span = .{
                .span = .{ .start = 0, .end = 2, .line = 1, .column = 1 },
                .role = .primary,
            } },
        },
    };

    try renderReport(alloc, &buf.writer, report);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "first problem") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "second problem") != null);
}
