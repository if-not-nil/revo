pub const default_macro_source =
    \\macro ok?! `(%what:expr)` `%what[0] == :ok`
    \\macro err?! `(%what:expr)` `%what[0] == :err`
    \\macro some?! `(%what:expr)` `%what[0] == :some`
    \\macro none?! `(%what:expr)` `%what == :none or %what[0] == :none`
    \\macro print! `(%fmt:str %ARGS(, %arg:expr)*)` `(print(fmt(%fmt %ARGS(, %arg))))`
;

pub fn build(vm: *VM, source: Source, opts: BuildOptions) !BuildResult {
    var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
    defer arena.deinit();

    const parsed = switch (try parse(arena.allocator(), source, .{
        .include_default_macros = opts.include_default_macros,
    })) {
        .ok => |ok| ok,
        .err => |failure| {
            var diag = failure;
            if (source.name) |name| diag.report.source_name = name;
            diag.report = try diag.report.copy(vm.runtime.diag_alloc);
            return .{ .err = .{ .parse = diag } };
        },
    };
    const expand_result = expandWithVmSource(
        vm,
        arena.allocator(),
        parsed,
        source.name orelse "",
        source.text,
    ) catch |err| return err;

    const expanded = switch (expand_result) {
        .ok => |ok| ok,
        .proc_err => |report| {
            var copied = try report.copy(vm.runtime.diag_alloc);
            copied.source_name = source.name;
            copied.source = source.text;
            return .{ .err = .{ .expand = .{ .report = copied } } };
        },
    };

    var type_annotations = std.AutoHashMap(*const Node, compiler.types.TypeInfo).init(vm.runtime.alloc);
    defer type_annotations.deinit();

    var known_globals = try std.ArrayList([]const u8)
        .initCapacity(vm.runtime.alloc, vm.const_globals.count());
    defer known_globals.deinit(vm.runtime.alloc);
    {
        var cit = vm.const_globals.keyIterator();
        while (cit.next()) |atom_id| {
            try known_globals.append(vm.runtime.alloc, vm.atomName(atom_id.*));
        }
        var git = vm.globals.iterator();
        while (git.next()) |entry| {
            try known_globals.append(vm.runtime.alloc, vm.atomName(entry.key_ptr.*));
        }
    }

    if (try lang.semantic.analyze(
        vm.runtime.alloc,
        expanded.root,
        source.name orelse "",
        source.text,
        known_globals.items,
        null,
        &type_annotations,
    )) |semantic_err| {
        var copied = try semantic_err.semantic.report.copy(vm.runtime.diag_alloc);
        copied.source_name = source.name;
        copied.source = source.text;
        deinitError(vm.runtime.alloc, semantic_err);
        return .{ .err = .{ .semantic = .{ .kind = semantic_err.semantic.kind, .report = copied } } };
    }

    const lower_result = try lower(vm, expanded, .{
        .install_debug_info = opts.install_debug_info,
        .source = source,
        .test_mode = opts.test_mode,
    }, &type_annotations);
    return switch (lower_result) {
        .ok => |artifact| .{ .ok = artifact },
        .err => |failure| .{ .err = .{ .lower = failure } },
    };
}

pub const Source = struct {
    text: []const u8,
    name: ?[]const u8 = null,
};

pub const ParseOptions = struct {
    include_default_macros: bool = false,
};

pub const LowerOptions = struct {
    install_debug_info: bool = false,
    source: ?Source = null,
    test_mode: bool = false,
};
pub const RunMode = enum {
    script,
    project,
};

pub const BuildOptions = struct {
    include_default_macros: bool = true,
    install_debug_info: bool = true,
    test_mode: bool = false,
    mode: RunMode = .script,
};

pub const Parsed = struct {
    root: *Node,
};

pub const Expanded = struct {
    root: *Node,
};

pub const ExpandFailure = struct {
    report: diagnostic.Report,
};

pub const Error = union(enum) {
    parse: parser.ParseFailure,
    expand: ExpandFailure,
    lower: compiler.LowerFailure,
    semantic: compiler.LowerFailure,
};

pub const ParseResult = Result(Parsed, parser.ParseFailure);
pub const ExpandError = expander.ExpandError || proc.ExpandError;
pub const ExpandResult = Result(Expanded, ExpandError);
pub const ExpandWithVmResult = union(enum) {
    ok: Expanded,
    proc_err: diagnostic.Report,
};
pub const LowerResult = Result(Artifact, compiler.LowerFailure);
pub const BuildResult = Result(Artifact, Error);

pub fn parse(allocator: std.mem.Allocator, source: Source, opts: ParseOptions) !ParseResult {
    if (!opts.include_default_macros) {
        return switch (try parseSourceReport(allocator, source.text)) {
            .ok => |expr| .{ .ok = .{ .root = expr } },
            .err => |failure| blk: {
                var diag = failure;
                if (source.name) |name| diag.report.source_name = name;
                break :blk .{ .err = diag };
            },
        };
    }

    const defaults: ParseResult = switch (try parseSourceReport(allocator, default_macro_source)) {
        .ok => |root| .{ .ok = .{ .root = root } },
        .err => |failure| .{ .err = failure },
    };
    if (defaults == .err) return .{ .err = defaults.err };
    const user: ParseResult = switch (try parseSourceReport(allocator, source.text)) {
        .ok => |root| .{ .ok = .{ .root = root } },
        .err => |failure| blk: {
            var diag = failure;
            if (source.name) |name| diag.report.source_name = name;
            break :blk .{ .err = diag };
        },
    };
    if (user == .err) return .{ .err = user.err };
    return .{ .ok = .{ .root = try mergeWithDefaults(allocator, defaults.ok.root, user.ok.root) } };
}

pub fn expand(allocator: std.mem.Allocator, parsed: Parsed) !ExpandResult {
    const template_expanded = expander.expandExpr(allocator, parsed.root) catch |err| return .{ .err = err };
    const final = expander.expandExpr(allocator, template_expanded) catch |err| return .{ .err = err };
    return .{ .ok = .{ .root = final } };
}

pub fn expandWithVm(vm: *VM, allocator: std.mem.Allocator, parsed: Parsed) !ExpandResult {
    const result = expandWithVmSource(vm, allocator, parsed, "", "") catch |err| return err;
    return switch (result) {
        .ok => |ok| .{ .ok = ok },
        .proc_err => |report| .{ .err = .{ .expand = .{ .report = report } } },
    };
}

pub fn expandWithVmSource(vm: *VM, allocator: std.mem.Allocator, parsed: Parsed, source_name: []const u8, source: []const u8) !ExpandWithVmResult {
    const template_expanded = try expander.expandExpr(allocator, parsed.root);
    const proc_result = try proc.expandExprWithSource(vm, allocator, template_expanded, source_name, source);
    if (proc_result.error_report) |report| return .{ .proc_err = report };
    const final = try expander.expandExpr(allocator, proc_result.root);
    return .{ .ok = .{ .root = final } };
}

pub fn lower(vm: *VM, expanded: Expanded, opts: LowerOptions, type_annotations: ?*const std.AutoHashMap(*const Node, compiler.types.TypeInfo)) !LowerResult {
    const lowered = try compiler.lowerExprArtifactReport(
        vm,
        expanded.root,
        opts.test_mode,
        type_annotations,
    );
    return switch (lowered) {
        .ok => |artifact| blk: {
            if (opts.install_debug_info) {
                const source: Source = opts.source orelse Source{ .text = "", .name = "<source>" };
                try vm.setProgramDebugInfo(artifact.spans, source.text, source.name orelse "<source>");
            }
            break :blk .{ .ok = artifact };
        },
        .err => |failure| blk: {
            var diag = failure;
            if (opts.source) |source| {
                if (source.name) |name| diag.report.source_name = name;
            }
            break :blk .{ .err = diag };
        },
    };
}

pub fn renderError(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: Source, err: Error) !void {
    return switch (err) {
        .parse => |failure| blk: {
            var report = failure.report;
            report.source_name = report.source_name orelse source.name;
            report.source = source.text;
            break :blk diagnostic.renderReport(allocator, writer, report);
        },
        .expand => |failure| blk: {
            break :blk diagnostic.renderReport(allocator, writer, failure.report);
        },
        .lower => |failure| blk: {
            var report = failure.report;
            report.source_name = report.source_name orelse source.name;
            report.source = source.text;
            break :blk diagnostic.renderReport(allocator, writer, report);
        },
        .semantic => |failure| blk: {
            var report = failure.report;
            report.source_name = report.source_name orelse source.name;
            report.source = source.text;
            break :blk diagnostic.renderReport(allocator, writer, report);
        },
    };
}

pub fn deinitError(alloc: std.mem.Allocator, err: Error) void {
    var mutable = err;
    switch (mutable) {
        .parse => |*failure| failure.report.deinit(alloc),
        .expand => |*failure| failure.report.deinit(alloc),
        .lower => |*failure| failure.report.deinit(alloc),
        .semantic => |*failure| failure.report.deinit(alloc),
    }
}

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) !*Node {
    return switch (try parseSourceReport(allocator, source)) {
        .ok => |expr| expr,
        .err => |failure| switch (failure.kind) {
            .LexUnexpectedCharacter => error.UnexpectedCharacter,
            .LexUnterminatedComment => error.UnterminatedComment,
            .LexUnterminatedString => error.UnterminatedString,
            .UnexpectedToken => error.UnexpectedToken,
            .ExpectedIdentifier => error.ExpectedIdentifier,
            .ExpectedMatchArm => error.ExpectedMatchArm,
            .LexUnknown => error.ParseFailed,
            .InvalidNumber => error.ParseFailed,
        },
    };
}

pub fn parseSourceReport(allocator: std.mem.Allocator, source: []const u8) !parser.ParseResult {
    const lexed = try Lexer.lexReport(allocator, source);
    const tokens = switch (lexed) {
        .ok => |items| items,
        .err => |failure| {
            const kind: parser.Kind = switch (failure.kind) {
                .UnexpectedCharacter => .LexUnexpectedCharacter,
                .UnterminatedComment => .LexUnterminatedComment,
                .UnterminatedString => .LexUnterminatedString,
                .Unknown => .LexUnknown,
            };
            const parts = try allocator.alloc(diagnostic.Part, 2);
            parts[0] = diagnostic.Part{ .@"error" = failure.message };
            parts[1] = .{ .span = .{ .span = failure.span, .role = .primary } };
            return .{ .err = .{
                .kind = kind,
                .report = .{ .parts = parts, .message = failure.message },
            } };
        },
    };
    defer allocator.free(tokens);
    return parser.parseTokensReport(allocator, tokens);
}

pub fn mergeWithDefaults(allocator: std.mem.Allocator, defaults: *Node, user: *Node) !*Node {
    var items = try std.ArrayList(*Node).initCapacity(allocator, 8);
    switch (defaults.expr) {
        .block => |block| try items.appendSlice(allocator, block),
        else => try items.append(allocator, defaults),
    }
    switch (user.expr) {
        .block => |block| {
            if (user.synthetic_block) {
                try items.appendSlice(allocator, block);
            } else {
                try items.append(allocator, user);
            }
        },
        else => try items.append(allocator, user),
    }
    const span = ast.Span.merge(defaults.span, user.span);
    const node = try allocator.create(Node);
    node.* = .{
        .span = span,
        .expr = .{ .block = try items.toOwnedSlice(allocator) },
    };
    return node;
}

const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;
const Result = revo.Result;

const lang = @import("./root.zig");
const ast = lang.ast;
const Node = ast.Node;
const compiler = lang.compiler;
const expander = lang.expander;
const proc = lang.proc;
const Lexer = lang.Lexer;
const parser = lang.parser;
const diagnostic = lang.diagnostic;
pub const Artifact = compiler.Artifact;
pub const ParseFailure = parser.ParseFailure;
pub const LowerFailure = compiler.LowerFailure;
