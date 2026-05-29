pub const default_macro_source =
    \\const ok? = macro `(%what:expr)` `%what[0] == :ok`
    \\const err? = macro `(%what:expr)` `%what[0] == :err`
    \\const some? = macro `(%what:expr)` `%what[0] == :some`
    \\const none? = macro `(%what:expr)` `%what == :none or %what[0] == :none`
    \\const print! = macro `(%fmt:str %ARGS(, %arg:expr)*)` `(print(fmt(%fmt %ARGS(, %arg))))`
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
            return .{ .err = .{ .parse = diag } };
        },
    };
    const expanded = switch (try expandWithVm(vm, arena.allocator(), parsed)) {
        .ok => |ok| ok,
        .err => |err| return err,
    };
    const lower_result = try lower(vm, expanded, .{
        .install_debug_info = opts.install_debug_info,
        .source = source,
        .test_mode = opts.test_mode,
    });
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
pub const BuildOptions = struct {
    include_default_macros: bool = true,
    install_debug_info: bool = true,
    test_mode: bool = false,
};

pub const Parsed = struct {
    root: *Node,
};

pub const Expanded = struct {
    root: *Node,
};

pub const Error = union(enum) {
    parse: parser.ParseFailure,
    lower: compiler.LowerFailure,
};

pub const ParseResult = Result(Parsed, parser.ParseFailure);
pub const ExpandError = expander.ExpandError || proc.ExpandError;
pub const ExpandResult = Result(Expanded, ExpandError);
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
    const template_expanded = expander.expandExpr(allocator, parsed.root) catch |err| return .{ .err = err };
    const proc_expanded = proc.expandExpr(vm, allocator, template_expanded) catch |err| return .{ .err = err };
    const final = expander.expandExpr(allocator, proc_expanded) catch |err| return .{ .err = err };
    return .{ .ok = .{ .root = final } };
}

pub fn lower(vm: *VM, expanded: Expanded, opts: LowerOptions) !LowerResult {
    const lowered = try compiler.lowerExprArtifactReport(
        vm,
        expanded.root,
        opts.test_mode,
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
        .lower => |failure| blk: {
            var report = failure.report;
            report.source_name = report.source_name orelse source.name;
            report.source = source.text;
            break :blk diagnostic.renderReport(allocator, writer, report);
        },
    };
}

pub fn deinitError(alloc: std.mem.Allocator, err: Error) void {
    switch (err) {
        .parse => |failure| failure.deinit(alloc),
        .lower => |failure| failure.deinit(alloc),
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
        },
    };
}

pub fn parseSourceReport(allocator: std.mem.Allocator, source: []const u8) !parser.ParseResult {
    const lexed = try lexer.lexReport(allocator, source);
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
                .report = .{ .parts = parts, .message = failure.message, .owned_parts = true },
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

const lang = @import("./root.zig");
const ast = lang.ast;
const Node = ast.Node;
const compiler = lang.compiler;
const expander = lang.expander;
const proc = lang.proc;
const lexer = lang.lexer;
const parser = lang.parser;
const diagnostic = lang.diagnostic;

const revo = @import("revo");
const VM = revo.VM;
const Result = revo.Result;

pub const Artifact = compiler.Artifact;
pub const ParseFailure = parser.ParseFailure;
pub const LowerFailure = compiler.LowerFailure;
