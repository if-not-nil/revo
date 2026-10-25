//! shared memory + report helpers for ws providers
//!
//! copy/free routines every provider needs so none of them
//! duplicate ownership logic

const std = @import("std");

const revo = @import("revo");

const diagnostic = @import("../diagnostic.zig");
const Lexer = @import("../Lexer.zig");
const pipeline = @import("../pipeline.zig");
const type_syntax = @import("../type_syntax.zig");
const types = @import("../compiler/types.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const Symbol = W.Symbol;
const FnSig = W.FnSig;

pub fn sameOpts(a: pipeline.BuildOptions, b: pipeline.BuildOptions) bool {
    return std.meta.eql(a, b);
}

pub fn copyBytecode(alloc: std.mem.Allocator, bytecode: pipeline.Bytecode) !pipeline.Bytecode {
    return .{
        .instructions = try alloc.dupe(revo.Instruction, bytecode.instructions),
        .spans = try alloc.dupe(Lexer.Span, bytecode.spans),
    };
}

pub fn deinitBytecode(alloc: std.mem.Allocator, bytecode: pipeline.Bytecode) void {
    alloc.free(bytecode.instructions);
    alloc.free(bytecode.spans);
}

/// merge two error reports into one (dedup span parts by range+message)
///
/// the merged report owns its arena; both inputs stay the caller's
pub fn mergeReports(alloc: std.mem.Allocator, a: pipeline.Error, b: pipeline.Error) !diagnostic.Report {
    const a_report = pipeline.errorReport(a);
    const b_report = pipeline.errorReport(b);

    var seed = a_report;
    seed.parts = &.{};
    seed.source_name = seed.source_name orelse b_report.source_name;
    seed.source = seed.source orelse b_report.source;
    seed.source_id = seed.source_id orelse b_report.source_id;
    seed.sources = seed.sources orelse b_report.sources;

    var merged = try seed.copyOwned(alloc);
    errdefer merged.deinit();
    const arena = merged.arenaAllocator().?;

    var all_parts = try std.ArrayList(diagnostic.Part).initCapacity(arena, a_report.parts.len + b_report.parts.len);
    for (a_report.parts) |part| try all_parts.append(arena, try part.copy(arena));
    for (b_report.parts) |part| {
        if (containsPart(all_parts.items, part)) continue;
        try all_parts.append(arena, try part.copy(arena));
    }

    merged.parts = try all_parts.toOwnedSlice(arena);
    merged.code = merged.code orelse b_report.code;
    if (merged.message.len == 0 and b_report.message.len > 0) {
        merged.message = try arena.dupe(u8, b_report.message);
    }
    return merged;
}

fn containsPart(existing: []const diagnostic.Part, part: diagnostic.Part) bool {
    for (existing) |e| {
        if (e == .span and part == .span) {
            if (e.span.span.start == part.span.span.start and
                e.span.span.end == part.span.span.end and
                std.mem.eql(u8, e.span.message, part.span.message)) return true;
        }
        if (e == .@"error" and part == .@"error") {
            if (std.mem.eql(u8, e.@"error", part.@"error")) return true;
        }
    }
    return false;
}

pub fn copyError(
    alloc: std.mem.Allocator,
    err: pipeline.Error,
    source_name: []const u8,
    source: []const u8,
) !pipeline.Error {
    var rep = pipeline.errorReport(err);
    rep.source_name = source_name;
    rep.source = source;
    const report = try rep.copyOwned(alloc);
    return switch (err) {
        .parse => |failure| .{ .parse = .{ .kind = failure.kind, .report = report } },
        .compile => |failure| .{ .compile = .{ .kind = failure.kind, .report = report } },
        .semantic => |failure| .{ .semantic = .{ .kind = failure.kind, .report = report } },
    };
}

pub fn copySymbols(alloc: std.mem.Allocator, symbols: []const Symbol) ![]Symbol {
    return copyFilteredSymbols(alloc, symbols, false);
}

/// one filtered copy for outlines + module members
///   params resolve for hover/definition but stay out of those lists
///   single home for `documentSymbols` + `symbolsFromDep`
pub fn copyFilteredSymbols(
    alloc: std.mem.Allocator,
    symbols: []const Symbol,
    comptime exclude_param: bool,
) ![]Symbol {
    var out = try std.ArrayList(Symbol).initCapacity(alloc, symbols.len);
    errdefer {
        for (out.items) |*s| {
            alloc.free(s.name);
            if (s.type_name) |*ti| types.deinitType(ti, alloc);
            if (s.field_values) |fvs| {
                for (fvs) |fv| {
                    alloc.free(fv.name);
                    alloc.free(fv.preview);
                }
                alloc.free(fvs);
            }
        }
        out.deinit(alloc);
    }

    for (symbols) |s| {
        if (exclude_param and s.kind == .param) continue;
        try out.append(alloc, .{
            .name = try alloc.dupe(u8, s.name),
            .kind = s.kind,
            .range = s.range,
            .type_name = if (s.type_name) |ti| try types.clone(ti, alloc) else null,
            .field_values = if (s.field_values) |fvs| try cloneFieldPreviews(alloc, fvs) else null,
        });
    }

    return out.toOwnedSlice(alloc);
}

pub fn cloneFieldPreviews(alloc: std.mem.Allocator, fvs: []const type_syntax.FieldPreview) ![]type_syntax.FieldPreview {
    const owned = try alloc.alloc(type_syntax.FieldPreview, fvs.len);
    for (fvs, owned) |fv, *dst| dst.* = .{
        .name = try alloc.dupe(u8, fv.name),
        .preview = try alloc.dupe(u8, fv.preview),
    };
    return owned;
}

pub fn freeSymbols(alloc: std.mem.Allocator, symbols: []Symbol) void {
    for (symbols) |*sym| {
        alloc.free(sym.name);
        if (sym.type_name) |*ti| types.deinitType(ti, alloc);
        if (sym.field_values) |fvs| {
            for (fvs) |fv| {
                alloc.free(fv.name);
                alloc.free(fv.preview);
            }
            alloc.free(fvs);
        }
    }
    alloc.free(symbols);
}

pub fn freeSigMap(alloc: std.mem.Allocator, map: *const std.StringHashMapUnmanaged(FnSig)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        for (entry.value_ptr.params) |*p| {
            if (p.name.len > 0) alloc.free(p.name);
            if (p.type_name) |*ti| types.deinitType(ti, alloc);
        }
        alloc.free(entry.value_ptr.params);
        if (entry.value_ptr.return_type) |*rt| types.deinitType(rt, alloc);
        if (entry.value_ptr.type_params_text) |t| alloc.free(t);
    }
    const mut = @constCast(map);
    mut.deinit(alloc);
}

/// `<T, U>` or null when empty
/// caller owns the result
pub fn formatTypeParams(alloc: std.mem.Allocator, type_params: []const []const u8) !?[]const u8 {
    if (type_params.len == 0) return null;
    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();
    try buf.writer.writeByte('<');

    for (type_params, 0..) |tp, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.writeAll(tp);
    }

    try buf.writer.writeByte('>');
    const owned: []const u8 = try buf.toOwnedSlice();
    return owned;
}

/// one `fn name(params) -> ret`, caller owns it
///   byte-identical to old `hover.renderDefinition` branch
pub fn formatSig(alloc: std.mem.Allocator, name: []const u8, sig: FnSig) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();

    try buf.writer.print("fn {s}", .{name});
    if (sig.type_params_text) |tps| try buf.writer.writeAll(tps);
    try buf.writer.writeByte('(');

    for (sig.params, 0..) |p, i| {
        if (i > 0) try buf.writer.print(", ", .{});
        try buf.writer.writeAll(p.name);
        if (p.optional) try buf.writer.writeByte('?');
        if (p.type_name) |ti| {
            const pt = try type_syntax.formatTypeOpts(alloc, ti, .{});
            defer alloc.free(pt);
            try buf.writer.print(": {s}", .{pt});
        }
    }

    try buf.writer.writeByte(')');
    if (sig.return_type) |rt| {
        const rt_str = try type_syntax.formatTypeOpts(alloc, rt, .{});
        defer alloc.free(rt_str);
        try buf.writer.print(" -> {s}", .{rt_str});
    }

    return buf.toOwnedSlice();
}

/// one baselib lookup so providers share a call site
///   replaces four `specs.findFn` spellings
pub fn baselibSig(name: []const u8) ?*const revo.baselib.specs.FnSpec {
    return revo.baselib.specs.findFn(name);
}

/// get known global names from the vm
pub fn getKnownGlobals(ws: *Workspace, alloc: std.mem.Allocator) ![]const []const u8 {
    const vm = ws.vm orelse return &.{};

    return pipeline.knownGlobalsFromVm(vm, alloc);
}


