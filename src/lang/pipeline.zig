//! parse -> check -> compile orchestration
//!   friends in pipeline/: scope_wiring, import_scan

pub fn build(vm: *VM, source: Source, opts: BuildOptions) !BuildResult {
    var dropped: ?diagnostic.Report = null;
    const result = try buildWithWarnings(vm, source, opts, &dropped);

    // warnings are owned copies, free them here
    // ; errors go to the caller
    if (dropped) |*wr| wr.deinit();
    return result;
}

/// known globals off the vm, caller owns the list
/// , frozen first, then user
pub fn knownGlobalsFromVm(vm: *VM, alloc: std.mem.Allocator) ![]const []const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(
        alloc,
        vm.frozen_globals.count() + vm.user_globals.count(),
    );

    var cit = vm.frozen_globals.keyIterator();
    while (cit.next()) |atom_id| {
        try list.append(alloc, vm.stringValue(atom_id.*));
    }

    var git = vm.user_globals.iterator();
    while (git.next()) |entry| {
        try list.append(alloc, vm.stringValue(entry.key_ptr.*));
    }

    return list.toOwnedSlice(alloc);
}

/// the report is owned by vm.runtime.alloc , deinit it when done
pub fn buildWithWarnings(vm: *VM, source: Source, opts: BuildOptions, warnings: *?diagnostic.Report) !BuildResult {
    var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
    defer arena.deinit();

    var parse_warn: ?diagnostic.Report = null;
    const parsed = switch (try parseWithWarnings(arena.allocator(), source, .{
        .repl_mode = opts.repl_mode,
    }, &parse_warn)) {
        .ok => |ok| ok,
        .err => |failure| {
            // copy into the per-cycle diag arena (borrowed); deinitError is a
            // no-op for these, resetDiagArena frees them
            var diag = failure;
            var rep = diag.report;
            if (source.name) |name| rep.source_name = name;
            rep.source = source.text;
            diag.report = try rep.copy(vm.runtime.diag_alloc);
            return .{ .err = .{ .parse = diag } };
        },
    };

    return buildParsedWithArena(vm, arena.allocator(), parsed.root, source, opts, parse_warn, warnings);
}

/// build a tree that already came out of `parse`/`parseWithWarnings`
///
/// ; the tree is borrowed and must stay alive for the build
/// , callers that cache parses use this to avoid lexing + parsing twice
pub fn buildParsedWithWarnings(
    vm: *VM,
    root: *Node,
    source: Source,
    opts: BuildOptions,
    parse_warnings: ?diagnostic.Report,
    warnings: *?diagnostic.Report,
) !BuildResult {
    var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
    defer arena.deinit();

    return buildParsedWithArena(vm, arena.allocator(), root, source, opts, parse_warnings, warnings);
}

fn buildParsedWithArena(
    vm: *VM,
    arena: std.mem.Allocator,
    root_in: *Node,
    source: Source,
    opts: BuildOptions,
    parse_warnings: ?diagnostic.Report,
    warnings: *?diagnostic.Report,
) !BuildResult {
    warnings.* = null;
    // set import_dir from source name so the resolver can find local modules
    const prev_import_dir = vm.import_dir;
    defer vm.import_dir = prev_import_dir;
    if (source.name) |name| {
        if (std.Io.Dir.path.dirname(name)) |dir| {
            vm.import_dir = dir;
        }
    }

    var parsed_root = root_in;

    // module scope? wrap cst to build exports table from pub decls
    if (opts.module_scope)
        parsed_root = try scope_wiring.wrapModule(arena, parsed_root);

    // closures with pub decls should return their @exports table
    parsed_root = try scope_wiring.wrapPubFunctions(arena, parsed_root);

    // desugar once
    //   parens stripped, pipes desugared; downstream gets canonical shapes (see hir)
    const root = try hir.lower(arena, parsed_root);

    // pointer-keyed and per-build only: the arena dies with this function,
    // so these addresses never outlive the tree
    var type_annotations = std.AutoHashMap(*const Node, compiler.types.TypeId).init(vm.runtime.alloc);
    defer type_annotations.deinit();

    var type_table = compiler.types.TypeTable.init(arena);
    const annotations = compiler.types.Annotations{
        .map = &type_annotations,
        .table = &type_table,
    };

    const known_globals = try knownGlobalsFromVm(vm, vm.runtime.alloc);
    defer vm.runtime.alloc.free(known_globals);

    const PipelineResolver = struct {
        fs: import_scan.Fs,

        fn resolve(ptr: *anyopaque, path: []const u8, a: std.mem.Allocator) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));

            if (comptime !revo.is_freestanding) {
                const resolved = (import_scan.resolveModuleFileWithFs(self.fs, path) catch return null) orelse return null;
                defer self.fs.alloc.free(resolved);

                // shared libs are opaque to the compiler; the module resolves untyped
                if (std.mem.endsWith(u8, resolved, ".so") or std.mem.endsWith(u8, resolved, ".dylib")) {
                    return null;
                }

                return std.Io.Dir.cwd().readFileAlloc(self.fs.io, resolved, a, std.Io.Limit.unlimited) catch null;
            }
            return null;
        }
    };

    var pipeline_resolver = PipelineResolver{ .fs = import_scan.Fs.fromVm(vm) };

    var combined_warnings = parse_warnings;
    if (try semantic.analyze(
        vm.runtime.alloc,
        root,
        source.name orelse "",
        source.text,
        known_globals,
        null,
        annotations,
        null,
        .{ .ptr = &pipeline_resolver, .resolveFn = PipelineResolver.resolve },
        &combined_warnings,
    )) |failure| {
        warnings.* = combined_warnings;
        // the failure owns its report arena; copy the parts into the per-cycle
        // diag arena for the caller, then free the original
        var rep = failure.report;
        rep.source_name = source.name;
        rep.source = source.text;
        const copied = try rep.copy(vm.runtime.diag_alloc);
        deinitError(.{ .semantic = failure });
        return .{ .err = .{ .semantic = .{ .kind = failure.kind, .report = copied } } };
    }
    warnings.* = combined_warnings;

    const compile_result = try compile(vm, root, .{
        .install_debug_info = opts.install_debug_info,
        .source = source,
        .test_mode = opts.test_mode,
        .annotation_stats = opts.annotation_stats,
    }, annotations);
    return switch (compile_result) {
        .ok => |bytecode| .{ .ok = bytecode },
        .err => |failure| .{ .err = .{ .compile = failure } },
    };
}

pub const Source = struct {
    text: []const u8,
    name: ?[]const u8 = null,
};

pub const Fs = import_scan.Fs;

pub const Sigs = struct {
    known_globals: []const []const u8 = &.{},

    pub fn fromVmGlobals(known_globals: []const []const u8) Sigs {
        return .{ .known_globals = known_globals };
    }
};

pub const ParseOptions = struct {
    repl_mode: bool = false,
};

pub const CompileOptions = struct {
    install_debug_info: bool = false,
    source: ?Source = null,
    test_mode: bool = false,
    /// optional annotation-cov counters for tests/tooling
    annotation_stats: ?*compiler.CompileStats = null,
};
pub const ProjectMode = enum {
    script,
    project,
};

pub const BuildOptions = struct {
    install_debug_info: bool = true,
    test_mode: bool = false,
    mode: ProjectMode = .script,
    module_scope: bool = false, // build exports table from pub decls
    repl_mode: bool = false,
    /// optional annotation-cov counters
    /// normally left null
    annotation_stats: ?*compiler.CompileStats = null,
};

fn parserOpts(opts: ParseOptions) Parser.Options {
    return .{ .repl_mode = opts.repl_mode };
}

pub const Parsed = struct {
    root: *Node,
};
pub const ParseResult = Result(Parsed, Parser.ParseFailure);
pub const Error = union(enum) {
    parse: Parser.ParseFailure,
    compile: compiler.CompileFailure,
    semantic: semantic.Failure,
};
pub const CompileResult = Result(Bytecode, compiler.CompileFailure);
pub const BuildResult = Result(Bytecode, Error);

pub fn parse(allocator: std.mem.Allocator, source: Source, opts: ParseOptions) !ParseResult {
    return parseWithWarnings(allocator, source, opts, null);
}

pub fn parseWithWarnings(
    allocator: std.mem.Allocator,
    source: Source,
    opts: ParseOptions,
    warnings: ?*?diagnostic.Report,
) !ParseResult {
    return switch (try Parser.parseSourceReportWithWarnings(allocator, source.text, parserOpts(opts), warnings)) {
        // name autobind imports after their targets, then lower
        // interpolation sugar first so users only see `fmt` calls
        .ok => |expr| blk: {
            if (warnings) |out| {
                if (out.*) |*w| w.source_name = source.name;
            }
            break :blk .{ .ok = .{ .root = try interpolation.lowerRoot(allocator, try scope_wiring.bindImportNames(allocator, expr)) } };
        },
        .err => |failure| blk: {
            var diag = failure;
            if (source.name) |name| diag.report.source_name = name;
            break :blk .{ .err = diag };
        },
    };
}

pub fn compile(
    vm: *VM,
    root: *Node,
    opts: CompileOptions,
    annotations: ?compiler.types.Annotations,
) !CompileResult {
    const compiled = try compiler.compileExprReportStats(
        vm,
        root,
        opts.test_mode,
        annotations,
        opts.annotation_stats,
        if (opts.source) |src| src.text else null,
    );
    return switch (compiled) {
        .ok => |bytecode| blk: {
            if (opts.install_debug_info) {
                const source: Source = opts.source orelse Source{ .text = "", .name = "<source>" };
                try vm.setProgramDebugInfo(bytecode.spans, source.text, source.name orelse "<source>");
            }
            break :blk .{ .ok = bytecode };
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

pub fn errorReport(err: Error) diagnostic.Report {
    return switch (err) {
        .parse => |failure| failure.report,
        .compile => |failure| failure.report,
        .semantic => |failure| failure.report,
    };
}

pub fn renderError(
    writer: *std.Io.Writer,
    source: Source,
    err: Error,
    opts: diagnostic.RenderOptions,
) !void {
    var report = errorReport(err);
    report.source_name = report.source_name orelse source.name;
    report.source = source.text;
    return diagnostic.renderReport(writer, report, opts);
}

/// render a warnings report
/// ; same shape as errors
/// , never fails the build
pub fn renderWarnings(writer: *std.Io.Writer, source: Source, report: diagnostic.Report, opts: diagnostic.RenderOptions) !void {
    var rep = report;
    rep.source_name = rep.source_name orelse source.name;
    rep.source = source.text;
    return diagnostic.renderReport(writer, rep, opts);
}

/// free an error produced by the pipeline; borrowed reports are a no-op
pub fn deinitError(err: Error) void {
    var report = errorReport(err);
    report.deinit();
}

const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;
const Result = revo.Result;

const cst = @import("cst.zig");
const Node = cst.CstNode;
const compiler = @import("compiler/root.zig");
const diagnostic = @import("diagnostic.zig");
const import_scan = @import("pipeline/import_scan.zig");
const interpolation = @import("pipeline/interpolation.zig");
const hir = @import("hir.zig");
const Parser = @import("Parser.zig");
const scope_wiring = @import("pipeline/scope_wiring.zig");
const semantic = @import("semantic.zig");
pub const Bytecode = compiler.Bytecode;
pub const ParseFailure = Parser.ParseFailure;
pub const CompileErrorKind = compiler.CompileErrorKind;
pub const CompileFailure = compiler.CompileFailure;
