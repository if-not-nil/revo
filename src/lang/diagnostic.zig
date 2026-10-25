const std = @import("std");

const revo = @import("revo");
const Lexer = @import("Lexer.zig");

const term = @import("../term.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// severity bucket for a diagnostic report
pub const Severity = enum { err, warning, note, help };

/// role for a span inside a report
pub const SpanRole = enum { primary, secondary, context, trace };

/// `err` for the wire, not the enum tag
pub fn severityName(severity: Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
        .help => "help",
    };
}

const COLOR_DIM = "\x1b[2m";
const COLOR_BOLD = "\x1b[1m";
const COLOR_DELETE = "\x1b[31m";
const COLOR_INSERT = "\x1b[32m";
const COLOR_RESET = "\x1b[0m";

// -- [sources] ---------------------------------------------------------------

/// handle into a SourceMap
pub const SourceId = u32;

/// shared table of source texts so parts can store an id instead of copying
/// the text into every SpanPart. the map must outlive every report using it
pub const SourceMap = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        name: []const u8,
        text: []const u8,
    };

    pub fn init() SourceMap {
        return .{};
    }

    /// frees the entry list, not the borrowed names/texts
    pub fn deinit(self: *SourceMap, alloc: Allocator) void {
        self.entries.deinit(alloc);
    }

    /// register a source, returning its id
    pub fn add(self: *SourceMap, alloc: Allocator, name: []const u8, text: []const u8) Allocator.Error!SourceId {
        try self.entries.append(alloc, .{ .name = name, .text = text });
        return @intCast(self.entries.items.len - 1);
    }

    pub fn get(self: *const SourceMap, id: SourceId) ?Entry {
        if (id >= self.entries.items.len) return null;
        return self.entries.items[id];
    }
};

// -- [parts] -----------------------------------------------------------------

/// one span entry attached to a report
pub const SpanPart = struct {
    span: Lexer.Span,
    role: SpanRole = .primary,
    message: []const u8 = "",
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    /// lookup into Report.sources, wins over the inline fields
    source_id: ?SourceId = null,
};

/// label tied to a span
pub const Label = struct {
    span: Lexer.Span,
    message: []const u8 = "",
};

/// plain note line
pub const Note = struct {
    message: []const u8,
};

/// an actionable edit: replacement text for span, empty span inserts
pub const Suggestion = struct {
    span: Lexer.Span,
    message: []const u8 = "",
    replacement: []const u8,
};

/// stack trace frame with optional source context
pub const TraceFrame = struct {
    function_name: []const u8,
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    span: ?Lexer.Span = null,
    pc: ?usize = null,

    /// empty frame shell
    pub fn empty() TraceFrame {
        return .{ .function_name = "" };
    }
};

/// frame names hidden from rendered traces
pub const hidden_frame_prefixes = [_][]const u8{ "<host", "<native", "<builtin" };

/// runtime bookkeeping frames users can't act on
pub fn isInternalFrame(frame: TraceFrame) bool {
    if (frame.function_name.len == 0) return true;
    for (hidden_frame_prefixes) |prefix| {
        if (std.mem.startsWith(u8, frame.function_name, prefix)) return true;
    }
    return false;
}

fn sameFrame(a: TraceFrame, b: TraceFrame) bool {
    if (!std.mem.eql(u8, a.function_name, b.function_name)) return false;
    const a_src = a.source_name orelse "";
    const b_src = b.source_name orelse "";
    if (!std.mem.eql(u8, a_src, b_src)) return false;
    const a_line = if (a.span) |s| s.line else 0;
    const b_line = if (b.span) |s| s.line else 0;
    return a_line == b_line;
}

/// one rendered part of a report
pub const Part = union(enum) {
    span: SpanPart,
    @"error": []const u8,
    tip: []const u8,
    warn: []const u8,
    note: []const u8,
    suggestion: Suggestion,
    trace: TraceFrame,

    /// deep copy every string into `arena`
    pub fn copy(part: Part, arena: Allocator) !Part {
        return switch (part) {
            inline else => |payload, tag| @unionInit(Part, @tagName(tag), try dupeStrings(arena, payload)),
        };
    }
};

/// dupe every `[]const u8` / `?[]const u8` field of a struct (or the string itself)
fn dupeStrings(arena: Allocator, value: anytype) Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    if (T == []const u8) return try arena.dupe(u8, value);
    if (T == ?[]const u8) return if (value) |s| try arena.dupe(u8, s) else null;

    var out = value;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, FieldType| {
        if (FieldType == []const u8 or FieldType == ?[]const u8) {
            @field(out, name) = try dupeStrings(arena, @field(value, name));
        }
    }
    return out;
}

// -- [report] ----------------------------------------------------------------

/// codes are lowercase kebab slugs always static strings
/// they must name the problem itself (not like the phase)
pub const Report = struct {
    parts: []const Part = &.{},
    message: []const u8 = "",
    severity: Severity = .err,
    code: ?[]const u8 = null,
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    /// lookup into `sources`, used when a part has no source of its own
    source_id: ?SourceId = null,
    sources: ?*const SourceMap = null,
    /// set only on owned reports; see `copyOwned` / `deinit`
    arena: ?*std.heap.ArenaAllocator = null,

    /// deepcopy borrowed text into arena
    /// the result borrows nothing
    pub fn copy(report: Report, arena: Allocator) !Report {
        const parts = try arena.alloc(Part, report.parts.len);
        for (report.parts, parts) |src, *dst| dst.* = try src.copy(arena);
        return .{
            .parts = parts,
            .message = try arena.dupe(u8, report.message),
            .severity = report.severity,
            .code = report.code,
            .source_name = if (report.source_name) |s| try arena.dupe(u8, s) else null,
            .source = if (report.source) |s| try arena.dupe(u8, s) else null,
            .source_id = report.source_id,
            .sources = report.sources,
        };
    }

    /// deepcopy into a fresh arena owned by report itself
    /// release with deinit
    pub fn copyOwned(report: Report, child: Allocator) Allocator.Error!Report {
        const arena = try child.create(std.heap.ArenaAllocator);
        errdefer child.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(child);
        errdefer arena.deinit();

        var out = try report.copy(arena.allocator());
        out.arena = arena;
        return out;
    }

    /// free an owned report; borrowed reports are a no-op
    pub fn deinit(self: *Report) void {
        const arena = self.arena orelse return;
        const child = arena.child_allocator;
        arena.deinit();
        child.destroy(arena);
        self.arena = null;
    }

    pub fn isOwned(self: Report) bool {
        return self.arena != null;
    }

    /// allocator of an owned report's arena, null for borrowed reports
    pub fn arenaAllocator(self: *const Report) ?Allocator {
        const arena = self.arena orelse return null;
        return arena.allocator();
    }

    /// the report-level source after id resolution
    pub fn baseSource(self: Report) ResolvedSource {
        if (self.source_id) |id| {
            if (self.sources) |map| {
                if (map.get(id)) |entry| return .{ .name = entry.name, .text = entry.text };
            }
        }
        return .{
            .name = self.source_name orelse "<source>",
            .text = self.source orelse "",
        };
    }

    /// the source a span part renders against:
    /// part id, part inline fields, report id, report inline fields
    pub fn sourceForSpan(self: Report, part: SpanPart) ResolvedSource {
        if (part.source_id) |id| {
            if (self.sources) |map| {
                if (map.get(id)) |entry| return .{ .name = entry.name, .text = entry.text };
            }
        }
        if (part.source_name != null or part.source != null) {
            const base = self.baseSource();
            return .{
                .name = part.source_name orelse base.name,
                .text = part.source orelse base.text,
            };
        }
        return self.baseSource();
    }
};

pub const ResolvedSource = struct {
    name: []const u8,
    text: []const u8,
};

/// first error message if the report has one
pub fn firstError(report: Report) ?[]const u8 {
    for (report.parts) |part| {
        if (part == .@"error") return part.@"error";
    }
    return null;
}

/// first warning message if the report has one
pub fn firstWarn(report: Report) ?[]const u8 {
    for (report.parts) |part| {
        if (part == .warn) return part.warn;
    }
    return null;
}

/// primary span if the report has one, else the first span of any role
pub fn primarySpan(report: Report) ?SpanPart {
    var fallback: ?SpanPart = null;
    for (report.parts) |part| {
        if (part != .span) continue;
        if (part.span.role == .primary) return part.span;
        if (fallback == null) fallback = part.span;
    }
    return fallback;
}

// -- [builder] ---------------------------------------------------------------

/// incremental pair builder for standalone reports
/// finish takes message + severity explicitly; code and source stay null
pub const DiagnosticBuilder = struct {
    alloc: Allocator,
    parts: std.ArrayList(Part),

    pub fn init(alloc: Allocator) DiagnosticBuilder {
        return .{ .alloc = alloc, .parts = .empty };
    }

    pub fn deinit(self: *DiagnosticBuilder) void {
        self.parts.deinit(self.alloc);
    }

    pub fn errOnly(self: *DiagnosticBuilder, message: []const u8) !void {
        try self.parts.append(self.alloc, .{ .@"error" = message });
    }

    pub fn err(self: *DiagnosticBuilder, message: []const u8, span: Lexer.Span) !void {
        try self.errLabel(message, span, "");
    }

    pub fn errLabel(self: *DiagnosticBuilder, message: []const u8, span: Lexer.Span, label: []const u8) !void {
        try self.errOnly(message);
        try self.primary(span, label);
    }

    pub fn warn(self: *DiagnosticBuilder, message: []const u8, span: Lexer.Span, label: []const u8) !void {
        try self.parts.append(self.alloc, .{ .warn = message });
        try self.primary(span, label);
    }

    pub fn primary(self: *DiagnosticBuilder, span: Lexer.Span, label: []const u8) !void {
        try self.parts.append(self.alloc, .{ .span = .{ .span = span, .role = .primary, .message = label } });
    }

    pub fn secondary(self: *DiagnosticBuilder, span: Lexer.Span, label: []const u8) !void {
        try self.parts.append(self.alloc, .{ .span = .{ .span = span, .role = .secondary, .message = label } });
    }

    pub fn note(self: *DiagnosticBuilder, message: []const u8) !void {
        try self.parts.append(self.alloc, .{ .note = message });
    }

    pub fn tip(self: *DiagnosticBuilder, message: []const u8) !void {
        try self.parts.append(self.alloc, .{ .tip = message });
    }

    pub fn suggestion(self: *DiagnosticBuilder, sug: Suggestion) !void {
        try self.parts.append(self.alloc, .{ .suggestion = sug });
    }

    pub fn finish(self: *DiagnosticBuilder, message: []const u8, severity: Severity) !Report {
        return .{
            .parts = try self.parts.toOwnedSlice(self.alloc),
            .message = message,
            .severity = severity,
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

// -- [lint levels] -----------------------------------------------------------

/// per-code lint level; errors can't be allowed away, only warnings can
pub const LintLevel = enum { allow, warn, deny };

pub const LintRule = struct {
    code: []const u8,
    level: LintLevel,
};

/// level configured for a code, null when nothing matches
pub fn lintLevelFor(code: ?[]const u8, rules: []const LintRule) ?LintLevel {
    const needle = code orelse return null;
    for (rules) |candidate| {
        if (std.mem.eql(u8, candidate.code, needle)) return candidate.level;
    }
    return null;
}

/// apply lint levels to a report
/// allow hides warnings/notes, deny promotes them to errors,
/// errors always pass through unchanged. null means suppressed
pub fn applyLint(report: Report, rules: []const LintRule) ?Report {
    if (report.severity != .warning and report.severity != .note) return report;
    switch (lintLevelFor(report.code, rules) orelse .warn) {
        .allow => return null,
        .warn => return report,
        .deny => {
            var promoted = report;
            promoted.severity = .err;
            return promoted;
        },
    }
}

// -- [typos] -----------------------------------------------------------------

/// levenshtein distance two rolling rows
pub fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    var prev = std.heap.page_allocator.alloc(usize, b.len + 1) catch return b.len;
    defer std.heap.page_allocator.free(prev);
    var curr = std.heap.page_allocator.alloc(usize, b.len + 1) catch return b.len;
    defer std.heap.page_allocator.free(curr);

    for (prev, 0..) |*slot, j| slot.* = j;

    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        for (b, 0..) |cb, j| {
            const sub = prev[j] + @as(usize, if (ca == cb) 0 else 1);
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), sub);
        }
        std.mem.swap([]usize, &prev, &curr);
    }
    return prev[b.len];
}

fn typoLimit(len: usize) usize {
    if (len <= 3) return 1;
    if (len <= 8) return 2;
    return 3;
}

/// closest candidate within the edit-distance limit, null when nothing is close
pub fn didYouMean(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    const limit = typoLimit(name.len);
    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);

    for (candidates) |candidate| {
        if (candidate.len == 0) continue;
        if (std.mem.eql(u8, name, candidate)) continue;

        // cheap length gate before the dp
        if (candidate.len > name.len + limit or name.len > candidate.len + limit)
            continue;

        const dist = editDistance(name, candidate);
        if (dist > limit) continue;
        if (dist < best_dist or (dist == best_dist and best != null and candidate.len < best.?.len)) {
            best = candidate;
            best_dist = dist;
        }
    }
    return best;
}

/// a suggestion with target `span` that renames a typo to the closest candidate
pub fn didYouMeanSuggestion(
    alloc: Allocator,
    name: []const u8,
    candidates: []const []const u8,
    span: Lexer.Span,
) !?Suggestion {
    const word = didYouMean(name, candidates) orelse return null;
    return .{
        .span = span,
        .message = try alloc.print("did you mean `{s}`?", .{word}),
        .replacement = word,
    };
}

// -- [collector] -------------------------------------------------------------

/// sink for many reports
pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    reports: std.ArrayList(Report) = .empty,
    opts: Options = .{},
    suppressed_warnings: usize = 0,
    suppressed_errors: usize = 0,
    aborted: bool = false,

    pub const Options = struct {
        /// stop collecting errors after this many (0 = unlimited)
        /// TODO: make it ?usize
        max_errors: usize = 100,
        dedup: bool = true,
        /// render in source order instead of arrival order
        sort: bool = true,
        /// print the job summary line after the reports
        footer: bool = true,
        show_warnings: bool = true,
        lints: []const LintRule = &.{},
    };

    pub fn init(child: Allocator, opts: Options) Diagnostics {
        return .{ .arena = std.heap.ArenaAllocator.init(child), .opts = opts };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.reports.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    /// deep-copied into the sink
    pub fn add(self: *Diagnostics, report: Report) Allocator.Error!void {
        const arena_alloc = self.arena.allocator();
        const linted = applyLint(report, self.opts.lints) orelse {
            self.suppressed_warnings += 1;
            return;
        };
        var rep = linted;

        if (!self.opts.show_warnings and (rep.severity == .warning or rep.severity == .note)) {
            self.suppressed_warnings += 1;
            return;
        }
        if (self.aborted) {
            if (rep.severity == .err) self.suppressed_errors += 1;
            return;
        }
        if (rep.severity == .err and self.opts.max_errors != 0 and self.errorCount() >= self.opts.max_errors) {
            self.suppressed_errors += 1;
            self.aborted = true;
            return;
        }
        if (self.opts.dedup and self.isDuplicate(rep)) return;

        const owned = try rep.copy(arena_alloc);
        try self.reports.append(arena_alloc, owned);
    }

    fn isDuplicate(self: *const Diagnostics, report: Report) bool {
        const primary = primarySpan(report);

        for (self.reports.items) |existing| {
            if (existing.severity != report.severity) continue;
            if (!std.mem.eql(u8, existing.message, report.message)) continue;

            const existing_code = existing.code orelse "";
            const report_code = report.code orelse "";

            if (!std.mem.eql(u8, existing_code, report_code)) continue;
            const existing_primary = primarySpan(existing);

            if (primary == null and existing_primary == null) return true;
            if (primary) |p| {
                if (existing_primary) |e| {
                    if (p.span.start == e.span.start and p.span.end == e.span.end) return true;
                }
            }
        }
        return false;
    }

    pub fn errorCount(self: *const Diagnostics) usize {
        var count: usize = 0;
        for (self.reports.items) |report| {
            if (report.severity == .err) count += 1;
        }

        return count;
    }

    pub fn warningCount(self: *const Diagnostics) usize {
        var count: usize = 0;
        for (self.reports.items) |report| {
            if (report.severity == .warning) count += 1;
        }

        return count;
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        return self.errorCount() > 0;
    }

    pub fn isEmpty(self: *const Diagnostics) bool {
        return self.reports.items.len == 0;
    }

    fn spanStart(report: Report) usize {
        const primary = primarySpan(report) orelse return std.math.maxInt(usize);
        return primary.span.start;
    }

    fn lessBySpan(_: void, a: Report, b: Report) bool {
        return spanStart(a) < spanStart(b);
    }

    fn order(self: *Diagnostics) void {
        if (!self.opts.sort) return;
        std.sort.insertion(Report, self.reports.items, {}, lessBySpan);
    }

    /// every report plus the footer
    pub fn render(self: *Diagnostics, w: *Writer, opts: RenderOptions) !void {
        self.order();
        var first = true;

        for (self.reports.items) |report| {
            if (!first) try w.writeByte('\n');
            first = false;
            try renderReport(w, report, opts);
        }

        try self.renderFooter(w, opts);
    }

    fn renderFooter(self: *Diagnostics, w: *Writer, opts: RenderOptions) !void {
        if (!self.opts.footer) return;
        if (self.reports.items.len > 0) try w.writeByte('\n');

        if (self.aborted) {
            const count = self.errorCount();
            var buf: [80]u8 = undefined;
            const msg = if (count == 1)
                "aborting due to 1 previous error"
            else
                try std.fmt.bufPrint(&buf, "aborting due to {d} previous errors", .{count});

            try printHeader(w, .err, null, msg, opts);
            if (self.suppressed_errors > 0) {
                try w.print("note: {d} more errors suppressed\n", .{self.suppressed_errors});
            }
        }

        if (self.suppressed_warnings > 0) {
            try w.print("note: {d} warnings suppressed\n", .{self.suppressed_warnings});
        }
    }

    pub fn renderJson(self: *Diagnostics, w: *Writer) !void {
        self.order();
        try w.writeAll("{\"diagnostics\":[");
        for (self.reports.items, 0..) |report, idx| {
            if (idx > 0) try w.writeByte(',');
            try renderReportJson(w, report);
        }
        try w.writeAll("]}");
    }
};

// -- [vm bridge] -------------------------------------------------------------

fn optStr(vm: *revo.VM, s: ?[]const u8) !revo.Value {
    return if (s) |text|
        try vm.ownValueString(text)
    else
        revo.Value.new.nil();
}

fn optNum(n: ?u32) revo.Value {
    return if (n) |x|
        revo.Value.new.num(x)
    else
        revo.Value.new.nil();
}

pub fn evalErrorTable(
    vm: *revo.VM,
    rep: Report,
    source_name: []const u8,
    source: []const u8,
    phase: []const u8,
    kind: ?[]const u8,
    trace: []const TraceFrame,
) !revo.Value {
    var owned = rep;
    owned.source_name = owned.source_name orelse source_name;
    owned.source = owned.source orelse source;
    const message: []const u8 = firstError(owned) orelse
        (if (owned.message.len != 0) owned.message else kind orelse "error");

    var rendered = Writer.Allocating.init(vm.runtime.alloc);
    defer rendered.deinit();
    try renderReport(&rendered.writer, owned, .{ .color = false });

    // lexer uses 0 for "unknown"
    const span = if (primarySpan(owned)) |sp| sp.span else null;
    const line: ?u32 = if (span) |s| (if (s.line == 0) null else s.line) else null;
    const column: ?u32 = if (span) |s| (if (s.column == 0) null else s.column) else null;

    const trace_id = try vm.tables.create();
    for (trace) |frame| {
        const id = try vm.tables.create();
        try vm.putField(id, "function", try vm.ownValueString(frame.function_name));
        try vm.putField(id, "source", try optStr(vm, frame.source_name));
        try vm.putField(id, "line", optNum(if (frame.span) |s| @max(s.line, 1) else null));
        try vm.putField(id, "column", optNum(if (frame.span) |s| @max(s.column, 1) else null));

        // re-fetch every time, creating tables may move them
        const trace_ptr = try vm.tables.get(trace_id);
        try trace_ptr.array.append(vm.runtime.alloc, revo.Value.new.table(id));
    }

    const tid = try vm.tables.create();
    // TODO: we are really lacking a way of converting a struct into a table
    try vm.putField(tid, "message", try vm.ownValueString(message));
    try vm.putField(tid, "phase", try vm.atomValue(phase));
    try vm.putField(tid, "code", try optStr(vm, owned.code));
    try vm.putField(tid, "line", optNum(line));
    try vm.putField(tid, "column", optNum(column));
    try vm.putField(tid, "source", try vm.ownValueString(owned.baseSource().name));
    try vm.putField(tid, "rendered", try vm.ownValueString(rendered.written()));
    try vm.putField(tid, "kind", try optStr(vm, kind));
    try vm.putField(tid, "trace", revo.Value.new.table(trace_id));
    return revo.Value.new.table(tid);
}

// -- [rendering] -------------------------------------------------------------

pub const RenderOptions = struct {
    color: bool = false,
    /// 0 = unlimited. source lines longer than this clip with "..."
    max_width: usize = 0,
    /// print up to two source lines around each span
    show_context: bool = true,

    /// color only when the environment and the terminal agree
    /// freestanding targets always come back uncolored
    pub fn auto(env: *std.process.Environ.Map, io: std.Io) RenderOptions {
        if (comptime revo.is_freestanding) {
            return .{ .color = false };
        } else {
            return .{ .color = term.isColorSupported(env, io) };
        }
    }
};

/// `error: text [slug]`, colored by severity
fn printHeader(
    w: *Writer,
    severity: Severity,
    code: ?[]const u8,
    text: []const u8,
    opts: RenderOptions,
) !void {
    const open: []const u8 = if (code != null) " [" else "";
    const close: []const u8 = if (code != null) "]" else "";
    const args = .{ text, open, code orelse "", close };

    switch (severity) {
        .err => try term.printError(w, opts.color, "{s}{s}{s}{s}", args),
        .warning => try term.printWarning(w, opts.color, "{s}{s}{s}{s}", args),
        .note => try term.printNote(w, opts.color, "{s}{s}{s}{s}", args),
        .help => try term.printHelp(w, opts.color, "{s}{s}{s}{s}", args),
    }
}

fn textSeverity(comptime tag: std.meta.Tag(Part)) Severity {
    return switch (tag) {
        .@"error" => .err,
        .warn => .warning,
        .tip => .help,
        .note => .note,
        else => unreachable,
    };
}

/// one inlineable secondary annotation
const Annotation = struct {
    span: Lexer.Span,
    message: []const u8,
};

pub fn renderReport(w: *Writer, report: Report, opts: RenderOptions) !void {
    if (report.parts.len == 0) {
        if (report.message.len != 0) try printHeader(w, report.severity, report.code, report.message, opts);
        return;
    }

    var seen = false; // a header was printed!! separate the next one with a blank line
    var frames: usize = 0;

    var i: usize = 0;
    while (i < report.parts.len) : (i += 1) {
        const part = report.parts[i];
        switch (part) {
            // only errors and warnings carry the flame
            inline .@"error", .tip, .warn, .note => |text, tag| {
                if (seen) try w.writeByte('\n');
                seen = true;
                const code = if (tag == .tip or tag == .note) null else report.code;
                try printHeader(w, textSeverity(tag), code, text, opts);
            },
            .span => |sp| {
                switch (sp.role) {
                    .primary => {
                        const src = report.sourceForSpan(sp);
                        var annotations: [8]Annotation = undefined;
                        const count = collectAnnotations(report, sp, src, &annotations);
                        try renderSpanBlock(w, src, sp.span, if (sp.message.len == 0) null else sp.message, annotations[0..count], opts);
                    },
                    .secondary => {
                        if (isInlined(report, sp)) continue;
                        const src = report.sourceForSpan(sp);
                        try renderSecondarySpan(w, src.name, sp.span, if (sp.message.len == 0) null else sp.message);
                    },
                    .context => {
                        if (!opts.show_context) continue;
                        const src = report.sourceForSpan(sp);
                        try renderSecondarySpan(w, src.name, sp.span, if (sp.message.len == 0) "context" else sp.message);
                    },
                    .trace => {},
                }
            },
            .suggestion => |sug| {
                if (seen) try w.writeByte('\n');
                seen = true;
                try renderSuggestion(w, report, sug, opts);
            },
            .trace => |frame| {
                if (isInternalFrame(frame)) continue;

                // collapse consecutive identical frames
                var repeats: usize = 0;
                while (i + 1 + repeats < report.parts.len) {
                    const next = report.parts[i + 1 + repeats];
                    if (next != .trace) break;
                    if (!sameFrame(frame, next.trace)) break;
                    repeats += 1;
                }

                if (frames == 0) try w.writeAll("\nstack trace:\n");
                try renderTrace(w, frame, frames);
                frames += 1;
                if (repeats > 0) {
                    try w.print("  ... {d} more\n", .{repeats});
                    i += repeats;
                }
            },
        }
    }
}

/// secondary spans that can be underlined under the primary
///   primary is single-line
fn collectAnnotations(
    report: Report,
    primary: SpanPart,
    primary_src: ResolvedSource,
    out: *[8]Annotation,
) usize {
    if (primary_src.text.len == 0) return 0;
    if (spanBlock(primary_src.text, primary.span).lines != 1) return 0;

    var count: usize = 0;
    const primary_line = lineStart(primary_src.text, @min(primary.span.start, primary_src.text.len));
    for (report.parts) |part| {
        if (count == out.len) break;
        if (part != .span) continue;

        const sp = part.span;
        if (sp.role != .secondary) continue;

        const src = report.sourceForSpan(sp);
        if (!sameSource(primary_src, src)) continue;

        const start = @min(sp.span.start, src.text.len);
        if (lineStart(src.text, start) != primary_line) continue;

        out[count] = .{ .span = sp.span, .message = sp.message };
        count += 1;
    }
    return count;
}

/// whether the report shows this secondary inline under a primary
fn isInlined(report: Report, sp: SpanPart) bool {
    const src = report.sourceForSpan(sp);
    if (src.text.len == 0) return false;
    const start = @min(sp.span.start, src.text.len);
    for (report.parts) |part| {
        if (part != .span) continue;

        const primary = part.span;
        if (primary.role != .primary) continue;

        const primary_src = report.sourceForSpan(primary);
        if (!sameSource(src, primary_src)) continue;
        if (spanBlock(primary_src.text, primary.span).lines != 1) continue;

        const primary_start = @min(primary.span.start, primary_src.text.len);
        if (lineStart(primary_src.text, primary_start) == lineStart(src.text, start))
            return true;
    }
    return false;
}

fn sameSource(a: ResolvedSource, b: ResolvedSource) bool {
    if (a.text.ptr == b.text.ptr and a.text.len == b.text.len) return true;
    return std.mem.eql(u8, a.text, b.text) and std.mem.eql(u8, a.name, b.name);
}

/// render an report from a span and labels
pub fn renderAt(
    w: *Writer,
    source_name: []const u8,
    source: []const u8,
    span: ?Lexer.Span,
    message: []const u8,
    labels: []const Label,
    notes: []const Note,
    opts: RenderOptions,
) !void {
    try printHeader(w, .err, null, message, opts);
    if (span) |s| {
        const src = ResolvedSource{ .name = source_name, .text = source };
        var annotations: [8]Annotation = undefined;
        var count: usize = 0;
        if (source.len != 0 and spanBlock(source, s).lines == 1) {
            const primary_line = lineStart(source, @min(s.start, source.len));
            for (labels) |label| {
                if (count == annotations.len) break;
                if (lineStart(source, @min(label.span.start, source.len)) != primary_line) continue;
                annotations[count] = .{ .span = label.span, .message = label.message };
                count += 1;
            }
        }
        try renderSpanBlock(w, src, s, null, annotations[0..count], opts);

        // labels that didnt fit inline keep the classic form
        for (labels) |label| {
            var inlined = false;
            for (annotations[0..count]) |annotation| {
                if (annotation.span.start == label.span.start and annotation.span.end == label.span.end) {
                    inlined = true;
                    break;
                }
            }
            if (!inlined) {
                try renderSecondarySpan(w, source_name, label.span, if (label.message.len == 0) null else label.message);
            }
        }
    } else {
        for (labels) |label| {
            try renderSecondarySpan(w, source_name, label.span, if (label.message.len == 0) null else label.message);
        }
    }
    for (notes) |n| {
        try w.writeByte('\n');
        try printHeader(w, .note, null, n.message, opts);
    }
}

fn renderTrace(w: *Writer, frame: TraceFrame, idx: usize) !void {
    const name = frame.source_name orelse "<source>";
    try w.print("  {d}: {s}", .{ idx, frame.function_name });

    if (frame.span) |span| {
        try w.print(" at {s}:{d}:{d}\n", .{ name, span.line, span.column });
    } else if (frame.pc) |pc| {
        try w.print(" at {s}:pc={d}\n", .{ name, pc });
    } else {
        try w.print(" at {s}\n", .{name});
    }
}

fn renderSecondarySpan(w: *Writer, source_name: []const u8, loc: Lexer.Span, label: ?[]const u8) !void {
    try w.print("  = {s}\n", .{label orelse "secondary span"});
    try w.print("    --> {s}:{d}:{d}\n", .{ source_name, @max(loc.line, 1), @max(loc.column, 1) });
}

// -- [suggestions] -----------------------------------------------------------

/// `help:` header was already printed by the caller
///
/// `+`/`-` diff markers in the gutter, where the line number goes
/// so that the code column never moves
///
///     help: add an explicit nil arm
///      --> t.rv:2:9
///        |
///      2 |  | 1 => 2
///      + |  | _ => :nil
///        |
fn renderSuggestion(w: *Writer, report: Report, sug: Suggestion, opts: RenderOptions) !void {
    try printHeader(w, .help, null, sug.message, opts);

    const src = report.baseSource();
    if (src.text.len == 0) {
        // no source at hand: keep the compact form
        try w.print("  + {s}\n", .{std.mem.trim(u8, sug.replacement, " \t\r\n")});
        return;
    }

    const start = @min(sug.span.start, src.text.len);
    const end = @min(@max(sug.span.end, start), src.text.len);
    const first_start = lineStart(src.text, start);
    const last_start = if (end > start) lineStart(src.text, end - 1) else first_start;
    const last_end = lineEnd(src.text, last_start);
    const line_no = countLines(src.text, first_start);
    const extra_lines: u32 = @intCast(std.mem.count(u8, src.text[first_start..last_start], "\n"));
    const width = @max(countDigits(line_no + extra_lines), 2);

    try w.print(" --> {s}:{d}:{d}\n", .{ src.name, line_no, @max(sug.span.column, 1) });
    try blankRule(w, width);

    if (start == end) {
        // insertion: show the untouched line, then the inserted text below it
        // a replacement that starts with a newline is a whole new line, any
        // other one lands at the insertion column
        try suggestionSourceRow(w, width, line_no, src.text[first_start..lineEnd(src.text, first_start)], opts);

        const whole_line = sug.replacement.len > 0 and
            (sug.replacement[0] == '\n' or sug.replacement[0] == '\r');

        var pad: usize = if (whole_line)
            0
        else
            displayWidth(src.text[first_start..start], 0);

        const trimmed = std.mem.trim(u8, sug.replacement, "\r\n");
        var lines = std.mem.splitScalar(u8, trimmed, '\n');

        while (lines.next()) |line| {
            try suggestionDiffRow(w, width, '+', pad, line, opts);
            pad = 0;
        }
    } else {
        // replacemen: whole-line diff around the span
        const new_chunks = [_][]const u8{
            src.text[first_start..start],
            sug.replacement,
            src.text[end..last_end],
        };

        var old_lines = std.mem.splitScalar(u8, trimCR(src.text[first_start..last_end]), '\n');
        while (old_lines.next()) |line| {
            try suggestionDiffRow(w, width, '-', 0, line, opts);
        }
        try suggestionChunkRows(w, width, &new_chunks, '+', opts);
    }

    try blankRule(w, width);
}

/// one untouched source row: number, then code
fn suggestionSourceRow(w: *Writer, width: usize, num: u32, text: []const u8, opts: RenderOptions) !void {
    try numPrefix(w, width, num);
    _ = try writeClipped(w, text, 0, opts.max_width);
    try w.writeByte('\n');
}

/// one changed row: `+`/`-` in the gutter, then code
fn suggestionDiffRow(
    w: *Writer,
    width: usize,
    marker: u8,
    pad: usize,
    text: []const u8,
    opts: RenderOptions,
) !void {
    try suggestionMarker(w, width, marker, opts);
    try repeat(w, ' ', pad);
    _ = try writeClipped(w, text, pad, opts.max_width);
    try w.writeByte('\n');
}

/// chunked text as `marker` rows
fn suggestionChunkRows(
    w: *Writer,
    width: usize,
    chunks: []const []const u8,
    marker: u8,
    opts: RenderOptions,
) !void {
    try suggestionMarker(w, width, marker, opts);

    for (chunks) |chunk| {
        for (chunk) |ch| {
            if (ch == '\n') {
                try w.writeByte('\n');
                try suggestionMarker(w, width, marker, opts);
            } else {
                try w.writeByte(ch);
            }
        }
    }
    try w.writeByte('\n');
}

/// `<pad>+ |  ` or `<pad>- |  `
fn suggestionMarker(w: *Writer, width: usize, marker: u8, opts: RenderOptions) !void {
    try repeat(w, ' ', width -| 1);
    if (opts.color) try w.writeAll(if (marker == '+') COLOR_INSERT else COLOR_DELETE);
    try w.writeByte(marker);
    if (opts.color) try w.writeAll(COLOR_RESET);
    try w.writeAll(" |  ");
}

/// apply every suggestion to `source`, ret fixed text
/// suggestions are applied in source order, overlapping ones skipped
pub fn applySuggestions(alloc: Allocator, source: []const u8, suggestions: []const Suggestion) ![]u8 {
    const order = try alloc.alloc(usize, suggestions.len);
    defer alloc.free(order);
    for (order, 0..) |*slot, idx| slot.* = idx;

    const Ctx = struct {
        suggestions: []const Suggestion,

        fn less(ctx: @This(), a: usize, b: usize) bool {
            return ctx.suggestions[a].span.start < ctx.suggestions[b].span.start;
        }
    };
    std.sort.insertion(usize, order, Ctx{ .suggestions = suggestions }, Ctx.less);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var cursor: usize = 0;

    for (order) |idx| {
        const sug = suggestions[idx];
        const start = @min(sug.span.start, source.len);
        const end = @min(@max(sug.span.end, start), source.len);
        if (start < cursor) continue; // overlap

        try out.appendSlice(alloc, source[cursor..start]);
        try out.appendSlice(alloc, sug.replacement);
        cursor = end;
    }

    try out.appendSlice(alloc, source[cursor..]);
    return out.toOwnedSlice(alloc);
}

// -- [source line plumbing] --------------------------------------------------

const Line = struct {
    num: u32,
    start: usize, // byte offset of `text` in the source
    text: []const u8,
};

/// the lines a span covers: [first, stop) in bytes
const Block = struct {
    first: usize,
    stop: usize,
    lines: u32,
};

/// up to two non-blank lines next to a span
const Context = struct {
    lines: [2]Line = undefined,
    len: usize = 0,

    fn slice(self: *const Context) []const Line {
        return self.lines[0..self.len];
    }
};

const LineIter = struct {
    source: []const u8,
    pos: usize,
    stop: usize,
    num: u32,

    fn init(source: []const u8, blk: Block, first_num: u32) LineIter {
        return .{ .source = source, .pos = blk.first, .stop = blk.stop, .num = first_num };
    }

    fn next(it: *LineIter) ?Line {
        if (it.pos >= it.stop) return null;
        const end = lineEnd(it.source, it.pos);
        const line: Line = .{ .num = it.num, .start = it.pos, .text = trimCR(it.source[it.pos..end]) };
        it.pos = end + 1;
        it.num += 1;
        return line;
    }
};

/// drop a trailing carriage return so crlf sources align
fn trimCR(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\r') return text[0 .. text.len - 1];
    return text;
}

/// byte offset where the line containing `pos` begins
fn lineStart(source: []const u8, pos: usize) usize {
    const head = source[0..@min(pos, source.len)];
    return if (std.mem.findScalarLast(u8, head, '\n')) |nl| nl + 1 else 0;
}

/// byte offset of the '\n' (or EOF) ending the line that contains `from`
fn lineEnd(source: []const u8, from: usize) usize {
    return from + (std.mem.findScalar(u8, source[from..], '\n') orelse source.len - from);
}

/// 1-based line number of the line starting at `start`
fn countLines(source: []const u8, start: usize) u32 {
    return @as(u32, @intCast(std.mem.count(u8, source[0..@min(start, source.len)], "\n"))) + 1;
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r").len == 0;
}

fn spanBlock(source: []const u8, loc: Lexer.Span) Block {
    const first = lineStart(source, loc.start);

    // an empty span still shows its line
    const end = if (loc.end > first) @min(loc.end, source.len) else @min(first + 1, source.len);
    var pos = first;
    var lines: u32 = 0;
    while (pos < end) : (lines += 1) pos = lineEnd(source, pos) + 1;

    return .{ .first = first, .stop = @min(pos, source.len), .lines = lines };
}

/// the two non-blank lines above `first`, in print order
fn contextBefore(source: []const u8, first: usize, first_num: u32) Context {
    var ctx: Context = .{};
    var start = first;
    var num = first_num;

    while (ctx.len < 2 and start > 0 and num > 1) {
        const end = start - 1; // the '\n' closing the previous line
        start = lineStart(source, end);
        num -= 1;

        const text = trimCR(source[start..end]);
        if (isBlank(text)) continue;

        ctx.lines[ctx.len] = .{ .num = num, .start = start, .text = text };
        ctx.len += 1;
    }

    std.mem.reverse(Line, ctx.lines[0..ctx.len]);
    return ctx;
}

/// the two non-blank lines at and after `from`
fn contextAfter(source: []const u8, from: usize, from_num: u32) Context {
    var ctx: Context = .{};
    var pos = from;
    var num = from_num;

    while (ctx.len < 2 and pos < source.len) : (num += 1) {
        const end = lineEnd(source, pos);
        const text = trimCR(source[pos..end]);
        const start = pos;

        pos = end + 1;
        if (isBlank(text)) continue;

        ctx.lines[ctx.len] = .{ .num = num, .start = start, .text = text };
        ctx.len += 1;
    }
    return ctx;
}

// -- [text helpers] ----------------------------------------------------------

// columns are byte-counted by the lexer, so tabs must be expanded or carets drift left
const tab_width = 2;

/// approx display width of one codepoint
/// kinda wonky but google overview just gave me these
fn charWidth(cp: u21) usize {
    // combining marks dont ahve width
    if ((cp >= 0x0300 and cp <= 0x036f) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f)) return 0;

    // east asian wide and emoji take two
    if ((cp >= 0x1100 and cp <= 0x115f) or
        (cp >= 0x2e80 and cp <= 0xa4cf) or
        (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe30 and cp <= 0xfe4f) or
        (cp >= 0xff00 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1faff) or
        (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

/// display columns `text` occupies
/// tabs snap to the next tab stop
fn displayWidth(text: []const u8, start_col: usize) usize {
    var col = start_col;
    var i: usize = 0;

    while (i < text.len) {
        const ch = text[i];
        if (ch == '\t') {
            col += tab_width - (col % tab_width);
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(ch) catch {
            col += 1;
            i += 1;
            continue;
        };
        if (i + len <= text.len) {
            if (std.unicode.utf8Decode(text[i..][0..len])) |cp| {
                col += charWidth(cp);
            } else |_| {
                col += 1;
            }
            i += len;
        } else {
            col += 1;
            i += 1;
        }
    }
    return col - start_col;
}

fn repeat(w: *Writer, ch: u8, n: usize) !void {
    for (0..n) |_| try w.writeByte(ch);
}

/// write `text` with tabs expanded to spaces, utf-8 sequences passed through
fn writeExpanded(w: *Writer, text: []const u8, start_col: usize) !void {
    var col = start_col;
    var i: usize = 0;

    while (i < text.len) {
        const ch = text[i];
        if (ch == '\t') {
            const n = tab_width - (col % tab_width);
            try repeat(w, ' ', n);
            col += n;
            i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(ch) catch 1;
        if (i + len <= text.len and len > 1) {
            if (std.unicode.utf8Decode(text[i..][0..len])) |cp| {
                try w.writeAll(text[i..][0..len]);
                col += charWidth(cp);
                i += len;
                continue;
            } else |_| {}
        }

        try w.writeByte(ch);
        col += 1;
        i += 1;
    }
}

/// write `text` clipped to `max_col` columns (0 = unlimited), returns written columns
fn writeClipped(w: *Writer, text: []const u8, start_col: usize, max_col: usize) !usize {
    if (max_col == 0) {
        try writeExpanded(w, text, start_col);
        return displayWidth(text, start_col);
    }

    const total = displayWidth(text, start_col);
    if (total <= max_col) {
        try writeExpanded(w, text, start_col);
        return total;
    }

    const budget = max_col -| 3;
    var col: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        const ch = text[i];
        if (ch == '\t') {
            const n = tab_width - ((start_col + col) % tab_width);
            if (col + n > budget) break;
            try repeat(w, ' ', n);
            col += n;
            i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(ch) catch 1;
        if (i + len > text.len) break;
        const width: usize = if (len == 1) 1 else blk: {
            const cp = std.unicode.utf8Decode(text[i..][0..len]) catch 0xFFFD;
            break :blk charWidth(cp);
        };

        if (col + width > budget) break;
        try w.writeAll(text[i..][0..len]);
        col += width;
        i += len;
    }

    try w.writeAll("...");
    return col + 3;
}

fn countDigits(value: u32) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits;
}

fn leadingWhitespaceLen(text: []const u8) usize {
    var idx: usize = 0;
    while (idx < text.len and (text[idx] == ' ' or text[idx] == '\t')) idx += 1;
    return idx;
}

/// `<width spaces> |<n spaces>`: the empty gutter
fn rule(w: *Writer, width: usize, after_pipe: usize) !void {
    try repeat(w, ' ', width);
    try w.writeAll(" |");
    try repeat(w, ' ', after_pipe);
}

fn blankRule(w: *Writer, width: usize) !void {
    try rule(w, width, 0);
    try w.writeByte('\n');
}

/// right-aligned line number gutter: ` 12 |  `
fn numPrefix(w: *Writer, width: usize, num: u32) !void {
    try repeat(w, ' ', width -| countDigits(num));
    try w.print("{d} |  ", .{num});
}

fn writeContext(w: *Writer, ctx: Context, width: usize, dim: bool, opts: RenderOptions) !void {
    if (dim and opts.color) try w.writeAll(COLOR_DIM);
    for (ctx.slice()) |l| {
        try numPrefix(w, width, l.num);
        _ = try writeClipped(w, l.text, 0, opts.max_width);
        try w.writeByte('\n');
    }

    if (dim and opts.color) try w.writeAll(COLOR_RESET);
}

// -- [span blocks] -----------------------------------------------------------

fn renderSpanBlock(
    w: *Writer,
    src: ResolvedSource,
    loc: Lexer.Span,
    label: ?[]const u8,
    annotations: []const Annotation,
    opts: RenderOptions,
) !void {
    const source_name = src.name;
    const source = src.text;
    const line = @max(loc.line, 1);
    try w.print(" --> {s}:{d}:{d}\n", .{ source_name, line, @max(loc.column, 1) });

    const blk = spanBlock(source, loc);
    if (blk.lines == 0) return;

    const before = if (opts.show_context) contextBefore(source, blk.first, line) else Context{};
    const after = if (opts.show_context) contextAfter(source, blk.stop, line + blk.lines) else Context{};
    const last_num = if (after.len > 0) after.lines[after.len - 1].num else line + blk.lines - 1;
    const width = @max(countDigits(last_num), 2);

    const multi = blk.lines > 1;
    const dim = multi;

    if (multi) {
        if (dim and opts.color) try w.writeAll(COLOR_DIM);
        try blankRule(w, width);
        if (dim and opts.color) try w.writeAll(COLOR_RESET);
    }
    if (before.len > 0) {
        try writeContext(w, before, width, dim, opts);
        try blankRule(w, width);
    }

    if (multi) {
        try renderBoxBody(w, source, loc, blk, line, width, label, opts);
    } else {
        try renderCarets(w, source, loc, blk, line, width, label, annotations, opts);
    }

    if (after.len > 0) {
        try blankRule(w, width);
        try writeContext(w, after, width, dim, opts);
    }
}

/// one line with `^~~~^` under the span, then one `---` row per inline secondary
fn renderCarets(
    w: *Writer,
    source: []const u8,
    loc: Lexer.Span,
    blk: Block,
    line: u32,
    width: usize,
    label: ?[]const u8,
    annotations: []const Annotation,
    opts: RenderOptions,
) !void {
    // i dont know how or why this works anymore sorry
    var it = LineIter.init(source, blk, line);
    const l = it.next().?;

    try numPrefix(w, width, l.num);
    const written = try writeClipped(w, l.text, 0, opts.max_width);
    const clipped = displayWidth(l.text, 0) > written;
    try w.writeByte('\n');

    const off = @min(loc.start - l.start, l.text.len);
    const pad = displayWidth(l.text[0..off], 0);
    const len = @min(loc.end -| loc.start, l.text.len - off);
    const highlight = @max(displayWidth(l.text[off..][0..len], pad), 1);

    try rule(w, width, 2);
    if (pad >= written and clipped) {
        // the span is past the clip: point at the ellipsis
        try w.writeAll("...");
        if (label) |msg| try w.print(" {s}", .{msg});
        try w.writeByte('\n');
        return;
    }

    try repeat(w, ' ', pad);
    if (opts.color) try w.writeAll(COLOR_BOLD);
    try w.writeByte('^');
    if (highlight > 1) {
        const visible = @min(highlight, written -| pad);
        try repeat(w, '~', visible -| 2);
        try w.writeByte('^');
    }

    if (opts.color) try w.writeAll(COLOR_RESET);
    if (label) |msg| try w.print(" {s}", .{msg});
    if (clipped) try w.writeAll(" ...");
    try w.writeByte('\n');

    for (annotations) |annotation| {
        const sec_off = @min(annotation.span.start - l.start, l.text.len);
        const sec_pad = displayWidth(l.text[0..sec_off], 0);

        if (clipped and sec_pad >= written) continue;
        const sec_len = @min(annotation.span.end -| annotation.span.start, l.text.len - sec_off);
        const sec_width = @max(displayWidth(l.text[sec_off..][0..sec_len], sec_pad), 1);
        try rule(w, width, 2);
        try repeat(w, ' ', sec_pad);

        if (opts.color) try w.writeAll(COLOR_DIM);
        const visible = if (clipped) @min(sec_width, written -| sec_pad) else sec_width;
        try repeat(w, '-', @max(visible, 1));

        if (annotation.message.len > 0) try w.print(" {s}", .{annotation.message});
        if (opts.color) try w.writeAll(COLOR_RESET);
        if (clipped) try w.writeAll(" ...");

        try w.writeByte('\n');
    }
}

/// several lines drawn inside a bracket:
///
///     +-----vvvv
///     | const x = 1 +
///     |   2
///     +-^ label
fn renderBoxBody(
    w: *Writer,
    source: []const u8,
    loc: Lexer.Span,
    blk: Block,
    first_num: u32,
    width: usize,
    label: ?[]const u8,
    opts: RenderOptions,
) !void {
    // one pass for shared indent and the first/last lines
    var indent: usize = std.math.maxInt(usize);
    var first: Line = undefined;
    var last: Line = undefined;
    var it = LineIter.init(source, blk, first_num);
    while (it.next()) |l| {
        if (l.num == first_num) first = l;
        last = l;
        if (!isBlank(l.text)) indent = @min(indent, leadingWhitespaceLen(l.text));
    }

    if (indent == std.math.maxInt(usize)) indent = 0;

    // shared indent trimmed, bar hugs the code
    const trim_w = trimWidth(first.text, indent);
    const bar = trim_w -| 4;

    const span_off = @min(loc.start - first.start, first.text.len);
    const top_dashes = displayWidth(first.text[0..span_off], 0) -| trim_w;
    const top_vs = @max(1, (displayWidth(first.text, 0) -| trim_w) -| top_dashes);

    const last_len = @min(loc.end -| last.start, last.text.len);
    const bottom_dashes = @max(1, displayWidth(last.text[0..last_len], 0) -| trimWidth(last.text, indent));

    try rule(w, width, 2);
    try repeat(w, ' ', bar);
    try w.writeByte('+');
    try repeat(w, '-', top_dashes + 1);
    try repeat(w, 'v', top_vs);
    try w.writeByte('\n');

    // long spans keep five lines at each end
    const elide = blk.lines > 10;
    var i: u32 = 0;
    it = LineIter.init(source, blk, first_num);
    while (it.next()) |l| : (i += 1) {
        if (elide and i >= 5 and i < blk.lines - 5) {
            if (i == 5) {
                if (opts.color) try w.writeAll(COLOR_DIM);
                try rule(w, width, 2);
                try repeat(w, ' ', bar);
                try w.print("... {d} lines ...\n", .{blk.lines - 10});
                if (opts.color) try w.writeAll(COLOR_RESET);
            }
            continue;
        }

        const cut = @min(indent, l.text.len);
        try numPrefix(w, width, l.num);
        try repeat(w, ' ', bar);
        try w.writeAll("| ");

        _ = try writeClipped(w, l.text[cut..], displayWidth(l.text[0..cut], 0), opts.max_width);
        try w.writeByte('\n');
    }

    try rule(w, width, 2);
    try repeat(w, ' ', bar);
    try w.writeByte('+');
    try repeat(w, '-', bottom_dashes);
    try w.writeByte('^');

    if (label) |msg| try w.print(" {s}", .{msg});
    try w.writeByte('\n');
}

fn trimWidth(text: []const u8, indent: usize) usize {
    return displayWidth(text[0..@min(indent, text.len)], 0);
}

// -- [machine] ---------------------------------------------------------------

fn writeJsonString(w: *Writer, text: []const u8) !void {
    try w.writeByte('"');

    for (text) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn writeJsonSpan(w: *Writer, prefix: []const u8, span: Lexer.Span) !void {
    try w.print("{s}\"start\":{d},\"end\":{d},\"line\":{d},\"column\":{d}", .{
        prefix, span.start, span.end, span.line, span.column,
    });
}

pub fn renderJson(w: *Writer, report: Report) !void {
    // public api, idk why i kept it separate but there must be a really reason for it
    return renderReportJson(w, report);
}

fn renderReportJson(w: *Writer, report: Report) !void {
    // this is just as ugly as it needs to be. its fine
    try w.writeAll("{\"severity\":");
    try writeJsonString(w, severityName(report.severity));
    try w.writeAll(",\"message\":");
    try writeJsonString(w, report.message);
    try w.writeAll(",\"code\":");
    try writeJsonString(w, report.code orelse "");

    const src = report.baseSource();
    try w.writeAll(",\"source\":");
    try writeJsonString(w, src.name);

    try w.writeAll(",\"parts\":[");
    for (report.parts, 0..) |part, idx| {
        if (idx > 0) try w.writeByte(',');
        switch (part) {
            .span => |sp| {
                try w.writeAll("{\"type\":\"span\",\"role\":");
                try writeJsonString(w, @tagName(sp.role));
                try writeJsonSpan(w, ",", sp.span);
                try w.writeAll(",\"message\":");
                try writeJsonString(w, sp.message);
                const part_src = report.sourceForSpan(sp);
                try w.writeAll(",\"source\":");
                try writeJsonString(w, part_src.name);
                try w.writeByte('}');
            },
            .suggestion => |sug| {
                try w.writeAll("{\"type\":\"suggestion\",\"message\":");
                try writeJsonString(w, sug.message);
                try writeJsonSpan(w, ",", sug.span);
                try w.writeAll(",\"replacement\":");
                try writeJsonString(w, sug.replacement);
                try w.writeByte('}');
            },
            .trace => |frame| {
                try w.writeAll("{\"type\":\"trace\",\"function\":");
                try writeJsonString(w, frame.function_name);
                try w.writeAll(",\"source\":");
                try writeJsonString(w, frame.source_name orelse "");
                if (frame.span) |span| {
                    try w.print(",\"line\":{d},\"column\":{d}", .{ span.line, span.column });
                }
                try w.writeByte('}');
            },
            inline .@"error", .tip, .warn, .note => |text, tag| {
                try w.writeAll("{\"type\":");
                try writeJsonString(w, @tagName(tag));
                try w.writeAll(",\"message\":");
                try writeJsonString(w, text);
                try w.writeByte('}');
            },
        }
    }
    try w.writeAll("]}");
}

// -- [lsp] -------------------------------------------------------------------

/// lsp positions are 0-based with utf-16 code units per character
pub const LspPosition = struct {
    line: u32,
    character: u32,
};

pub const LspRange = struct {
    start: LspPosition,
    end: LspPosition,
};

fn utf16Len(cp: u21) u32 {
    return if (cp >= 0x10000) 2 else 1;
}

/// byte offset => lsp position
pub fn lspPosition(source: []const u8, offset: usize) LspPosition {
    const upto = source[0..@min(offset, source.len)];
    var line: u32 = 0;
    var character: u32 = 0;

    var i: usize = 0;
    while (i < upto.len) {
        if (upto[i] == '\n') {
            line += 1;
            character = 0;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(upto[i]) catch {
            character += 1;
            i += 1;
            continue;
        };
        if (i + len <= upto.len) {
            if (std.unicode.utf8Decode(upto[i..][0..len])) |cp| {
                character += utf16Len(cp);
            } else |_| {
                character += 1;
            }
            i += len;
        } else {
            character += 1;
            i += 1;
        }
    }
    return .{ .line = line, .character = character };
}

/// byte span into => lsp range
pub fn lspRange(source: []const u8, span: Lexer.Span) LspRange {
    return .{
        .start = lspPosition(source, span.start),
        .end = lspPosition(source, span.end),
    };
}

// -- [tests] -----------------------------------------------------------------

fn expectHas(output: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, output, needle) != null);
}

test "single line span" {
    var buf = Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try renderAt(
        &buf.writer,
        "example.rv",
        "let x = 1\nlet y = 2\n",
        .{ .start = 4, .end = 5, .line = 1, .column = 5 },
        "boom",
        &.{.{ .span = .{ .start = 14, .end = 15, .line = 2, .column = 5 }, .message = "here" }},
        &.{.{ .message = "try something else" }},
        .{},
    );
    const output = buf.written();
    try expectHas(output, "-->");
    try expectHas(output, "let y = 2");
    try expectHas(output, "try something else");
}

test "multi-line span with bracket" {
    var buf = Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try renderAt(
        &buf.writer,
        "multi.rv",
        \\before
        \\const x: string = 1 +
        \\  2 +
        \\  3
        \\after
    ,
        .{ .start = 14, .end = 36, .line = 2, .column = 18 },
        "x wants string, got number",
        &.{},
        &.{},
        .{},
    );
    const output = buf.written();
    try expectHas(output, "-->");
    try expectHas(output, "before");
    try expectHas(output, "const x: string = 1 +");
    try expectHas(output, "|   2 +");
    try expectHas(output, "|   3");
    try expectHas(output, "+-^");
    try expectHas(output, "x wants string, got number");
    try expectHas(output, "after");
}

test "RenderOptions.auto is wired to the shared color policy" {
    // forces the function to be analyzed; the policy itself is term's
    _ = &RenderOptions.auto;
    const opts = RenderOptions{};
    try std.testing.expect(!opts.color);
    try std.testing.expectEqual(@as(usize, 0), opts.max_width);
    try std.testing.expect(opts.show_context);
}

test "blank line inside an indented multi-line span" {
    var buf = Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    const src = "    a\n\n    b\n";
    try renderAt(
        &buf.writer,
        "blank.rv",
        src,
        .{ .start = 4, .end = 12, .line = 1, .column = 5 },
        "boom",
        &.{},
        &.{},
        .{},
    );
    try expectHas(buf.written(), "+-^");
}

test "report copy preserves multiple error parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

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

    const copied = try report.copy(arena.allocator());
    try std.testing.expectEqualStrings("first problem", copied.message);
    try std.testing.expectEqualStrings("first problem", copied.parts[0].@"error");
    try std.testing.expectEqualStrings("second problem", copied.parts[1].@"error");
}

test "render report prints multiple error blocks" {
    var buf = Writer.Allocating.init(std.testing.allocator);
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

    try renderReport(&buf.writer, report, .{});
    try expectHas(buf.written(), "first problem");
    try expectHas(buf.written(), "second problem");
}

test "warnings report renders severity and code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf = Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    const report: Report = .{
        .severity = .warning,
        .code = "non-exhaustive-match",
        .message = "match is not exhaustive: :err not covered, miss yields :nil",
        .source_name = "<source>",
        .source = "match x\n",
        .parts = &.{
            .{ .warn = "match is not exhaustive: :err not covered, miss yields :nil" },
            .{ .span = .{
                .span = .{ .start = 0, .end = 7, .line = 1, .column = 1 },
                .role = .primary,
                .message = "non-exhaustive match",
            } },
        },
    };

    try renderReport(&buf.writer, report, .{});
    try expectHas(buf.written(), "warning:");
    try expectHas(buf.written(), "[non-exhaustive-match]");
    try expectHas(buf.written(), "match x");

    const copied = try report.copy(arena.allocator());
    try std.testing.expect(copied.severity == .warning);
    try std.testing.expectEqualStrings("non-exhaustive-match", copied.code.?);
}

test "suggestion renders as help with replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf = Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    const report: Report = .{
        .severity = .warning,
        .code = "non-exhaustive-match",
        .message = "match is not exhaustive",
        .source_name = "<source>",
        .source = "match x\n",
        .parts = &.{
            .{ .warn = "match is not exhaustive" },
            .{ .suggestion = .{
                .span = .{ .start = 7, .end = 7, .line = 1, .column = 8 },
                .message = "add an explicit nil arm",
                .replacement = "\n| _ => :nil",
            } },
        },
    };

    try renderReport(&buf.writer, report, .{});
    try expectHas(buf.written(), "help:");
    try expectHas(buf.written(), "add an explicit nil arm");
    // the marker takes the number's place, so the code column is the same
    try expectHas(buf.written(), "1 |  match x");
    try expectHas(buf.written(), " + |  | _ => :nil");
    // the leading newline in the replacement must not render an empty `+` row
    try std.testing.expect(std.mem.find(u8, buf.written(), "+ |  \n") == null);

    const sug = (try report.copy(arena.allocator())).parts[1].suggestion;
    try std.testing.expectEqualStrings("add an explicit nil arm", sug.message);
    try std.testing.expectEqualStrings("\n| _ => :nil", sug.replacement);
}

test "render options decide color, and nothing else does" {
    const src =
        \\let x = 1
        \\let y = 2
    ;
    const span = Lexer.Span{ .start = 0, .end = 5, .line = 1, .column = 1 };

    var plain = Writer.Allocating.init(std.testing.allocator);
    defer plain.deinit();
    try renderAt(&plain.writer, "t.rv", src, span, "boom", &.{}, &.{}, .{ .color = false });

    var colored = Writer.Allocating.init(std.testing.allocator);
    defer colored.deinit();
    try renderAt(&colored.writer, "t.rv", src, span, "boom", &.{}, &.{}, .{ .color = true });

    try std.testing.expect(std.mem.find(u8, plain.written(), "\x1b[") == null);
    try expectHas(colored.written(), "\x1b[");
    try expectHas(colored.written(), "let y = 2");
    try expectHas(plain.written(), "let y = 2");
}
