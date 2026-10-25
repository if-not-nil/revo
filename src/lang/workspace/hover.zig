//! markdown hover + definition-line rendering

const std = @import("std");

const revo = @import("revo");

const common = @import("common.zig");
const pipeline = @import("../pipeline.zig");
const txt = @import("text.zig");
const type_syntax = @import("../type_syntax.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Position = W.Position;
const Range = W.Range;
const Hover = W.Hover;
const Symbol = W.Symbol;

/// markdown hover, kind + type + where its from + where it lives
pub fn hover(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    pos: Position,
    opts: pipeline.BuildOptions,
) !?Hover {
    const snap = self.snapshot(id) orelse return null;
    const name = txt.wordAtPosition(snap.text, pos) orelse return null;

    const def_opt = try self.definition(alloc, id, pos, opts);
    if (def_opt == null) {
        // qualified baselib member (`math.floor`): resolve through the
        // module first so duplicated names don't fall through to whichever
        // module comes first (e.g. `number.floor`)
        if (txt.moduleMemberAt(snap.text, pos)) |mod_name| {
            if (revo.baselib.specs.isModule(mod_name)) {
                var qbuf: [256]u8 = undefined;
                const qualified = std.mem.print(&qbuf, "{s}.{s}", .{ mod_name, name }) catch null;
                if (qualified) |q| {
                    if (revo.baselib.specs.findQualified(q)) |spec| {
                        return try renderSpecHover(alloc, spec, snap.text, pos, name);
                    }
                }
            }
        }
        if (common.baselibSig(name)) |spec| {
            return try renderSpecHover(alloc, spec, snap.text, pos, name);
        }
        //
        // member off an imported module, `mod.member` shows its def
        if (txt.moduleMemberAt(snap.text, pos)) |mod_name| {
            const fid = self.resolveDepId(alloc, id, mod_name) orelse id;
            const mod_syms = self.symbolsFromDep(alloc, fid) catch null;
            if (mod_syms) |ms| {
                defer common.freeSymbols(alloc, @constCast(ms));
                for (ms) |s| {
                    if (!std.mem.eql(u8, s.name, name)) continue;
                    const sym_tn = if (s.type_name) |ti| try type_syntax.formatTypeOpts(alloc, ti, .{}) else "";
                    defer if (sym_tn.len > 0) alloc.free(sym_tn);

                    const display = try renderDefinitionOpts(alloc, name, sym_tn, self, fid, opts);
                    defer alloc.free(display);
                    var buf = std.Io.Writer.Allocating.init(alloc);
                    defer buf.deinit();

                    try buf.writer.print("```revo\n{s}\n```", .{display});
                    return .{
                        .text = try buf.toOwnedSlice(),
                        .range = txt.wordRangeAt(snap.text, pos) orelse .{
                            .start = pos,
                            .end = .{
                                .line = pos.line,
                                .character = pos.character + @as(u32, @intCast(name.len)),
                            },
                        },
                    };
                }
            }
        }
        // baselib module name (`math` in `math.floor`)
        if (revo.baselib.specs.isModule(name)) {
            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try buf.writer.print("module `{s}`", .{name});

            const mod_doc = revo.baselib.specs.moduleDoc(name);
            if (mod_doc.len > 0) try buf.writer.print("\n\n{s}", .{mod_doc});
            try buf.writer.writeAll("\n\n```revo\n");

            for (revo.baselib.specs.full_specs) |group| {
                for (group) |*spec| {
                    if (spec.is_type) continue;
                    const ours = spec.head.kind == .namespaced and spec.head.module != null and
                        std.mem.eql(u8, spec.head.module.?, name);
                    if (!ours) continue;
                    try revo.baselib.specs.renderSignature(&buf.writer, spec.*);
                    try buf.writer.writeByte('\n');
                }
            }

            try buf.writer.writeAll("```");
            return .{
                .text = try buf.toOwnedSlice(),
                .range = txt.wordRangeAt(snap.text, pos) orelse .{
                    .start = pos,
                    .end = .{
                        .line = pos.line,
                        .character = pos.character + @as(u32, @intCast(name.len)),
                    },
                },
            };
        }
        return null;
    }
    const def = def_opt orelse return null;

    var type_name: []const u8 = "";
    var record_display: []const u8 = "";
    {
        const entry = try self.ensureInspect(alloc, def.file_id, opts);

        for (entry.symbols) |sym| {
            if (!std.mem.eql(u8, sym.name, name)) continue;
            if (def.file_id == id and sym.range.start.line != def.range.start.line) continue;
            // cross-file takes the first name hit, same-file wants name+line
            type_name = if (sym.type_name) |ti| try type_syntax.formatTypeOpts(alloc, ti, .{}) else "";
            record_display = try renderRecordDisplay(alloc, sym);
            break;
        }
    }
    defer if (type_name.len > 0) alloc.free(type_name);
    defer if (record_display.len > 0) alloc.free(record_display);

    if (self.resolveDepId(alloc, id, name)) |dep_id| {
        const mod_syms = self.symbolsFromDep(alloc, dep_id) catch null;
        if (mod_syms) |ms| {
            defer common.freeSymbols(alloc, @constCast(ms));

            if (ms.len > 0) {
                var buf = std.Io.Writer.Allocating.init(alloc);
                defer buf.deinit();
                try buf.writer.print("module `{s}`\n\n```revo\n", .{name});

                for (ms) |s| {
                    if (try self.fnSigOpts(alloc, dep_id, s.name, opts) != null) {
                        const sym_tn = if (s.type_name) |ti| try type_syntax.formatTypeOpts(alloc, ti, .{}) else "";
                        defer if (sym_tn.len > 0) alloc.free(sym_tn);

                        const display = try renderDefinitionOpts(alloc, s.name, sym_tn, self, dep_id, opts);
                        defer alloc.free(display);

                        try buf.writer.writeAll(display);
                    } else {
                        if (self.snapshot(dep_id)) |ss| {
                            var line = txt.sourceLine(ss.text, s.range.start.line);
                            line = std.mem.trim(u8, line, " \t\r");
                            line = txt.stripPub(line);
                            try buf.writer.writeAll(line);
                        } else try buf.writer.writeAll(s.name);
                    }
                    try buf.writer.writeByte('\n');
                }
                try buf.writer.writeAll("```");

                return .{
                    .text = try buf.toOwnedSlice(),
                    .range = def.range,
                };
            }
        }
    }

    var doc_text: []const u8 = "";
    {
        const entry = try self.ensureInspect(alloc, def.file_id, opts);
        if (entry.docs.get(name)) |d| doc_text = d;
    }
    const display = blk: {
        if (try self.fnSigOpts(alloc, def.file_id, name, opts) != null)
            break :blk try renderDefinitionOpts(alloc, name, type_name, self, def.file_id, opts);
        if (record_display.len > 0) break :blk try alloc.dupe(u8, record_display);
        if (self.snapshot(def.file_id)) |ss|
            break :blk try renderBindingLine(alloc, ss.text, def.range, type_name);
        break :blk try renderDefinitionOpts(alloc, name, type_name, self, def.file_id, opts);
    };
    defer alloc.free(display);
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    try buf.writer.writeAll("```revo\n");
    try buf.writer.writeAll(display);
    try buf.writer.writeAll("\n```");
    if (doc_text.len > 0) {
        try buf.writer.print("\n\n{s}", .{doc_text});
    }
    // cross-file ranges mean nothing over here, use the call-site word
    const range: Range = if (def.file_id == id)
        def.range
    else
        (txt.wordRangeAt(snap.text, pos) orelse def.range);
    return .{
        .text = try buf.toOwnedSlice(),
        .range = range,
    };
}

/// hover for a name you already hold, null when it binds nowhere here
pub fn hoverByName(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    name: []const u8,
) !?[]const u8 {
    const cache = try self.ensureInspect(alloc, id, .{});

    const doc = cache.docs.get(name);
    const sig = cache.sig_map.get(name);

    var sym_range: ?Range = null;
    var type_name: []const u8 = "";
    defer if (type_name.len > 0) alloc.free(type_name);
    for (cache.symbols) |sym| {
        if (!std.mem.eql(u8, sym.name, name)) continue;
        sym_range = sym.range; // last binding wins
        if (sym.type_name) |ti| {
            if (type_name.len > 0) alloc.free(type_name);
            type_name = try type_syntax.formatTypeOpts(alloc, ti, .{});
        }
    }
    if (doc == null and sig == null and sym_range == null) return null;

    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    if (sig != null) {
        const display = try renderDefinition(alloc, name, type_name, self, id);
        defer alloc.free(display);
        try buf.writer.writeAll(display);
    } else if (sym_range) |def_range| {
        if (self.snapshot(id)) |ss| {
            const line = try renderBindingLine(alloc, ss.text, def_range, type_name);
            defer alloc.free(line);
            try buf.writer.writeAll(line);
        } else {
            try buf.writer.writeAll(name);
        }
    } else {
        try buf.writer.writeAll(name);
    }
    if (doc) |d| try buf.writer.print("\n\n{s}", .{d});
    return try buf.toOwnedSlice();
}

/// `t: {name: string = "me"}`
///
/// for record-typed bindings with known literal values
/// "" when inapplicable (caller falls back)
fn renderRecordDisplay(alloc: std.mem.Allocator, sym: Symbol) ![]const u8 {
    const ti = sym.type_name orelse return "";
    if (ti.tag != .table) return "";
    if (ti.tag.table.fields == null) return "";
    const previews = sym.field_values orelse return "";
    if (previews.len == 0) return "";

    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();
    try type_syntax.printType(ti, &buf.writer, .{ .values = previews });
    const record = try buf.toOwnedSlice();
    defer alloc.free(record);

    return try alloc.print("{s}: {s}", .{ sym.name, record });
}

/// a value binding's source line, pub-stripped, `(type = t)` appended if
/// the inferred type isn't visible in it
fn renderBindingLine(
    alloc: std.mem.Allocator,
    text: []const u8,
    def_range: Range,
    type_name: []const u8,
) ![]const u8 {
    var line = txt.sourceLine(text, def_range.start.line);
    line = std.mem.trim(u8, line, " \t\r");
    line = txt.stripPub(line);
    if (type_name.len > 0 and std.mem.find(u8, line, type_name) == null)
        return alloc.print("{s}\n(type = {s})", .{ line, type_name });
    return alloc.dupe(u8, line);
}

/// one def line, `fn name(p, ...) -> ret` when theres a sig
///   else bare name or type_name
pub fn renderDefinition(
    alloc: std.mem.Allocator,
    name: []const u8,
    type_name: []const u8,
    ws: *Workspace,
    file_id: FileId,
) ![]const u8 {
    return renderDefinitionOpts(alloc, name, type_name, ws, file_id, .{});
}

/// hover card for one baselib spec: qualified sig plus doc, call-site range
fn renderSpecHover(
    alloc: std.mem.Allocator,
    spec: *const revo.baselib.specs.FnSpec,
    text: []const u8,
    pos: Position,
    name: []const u8,
) !Hover {
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    try buf.writer.writeAll("```revo\n");
    try revo.baselib.specs.renderSignature(&buf.writer, spec.*);
    try buf.writer.writeAll("\n```");
    if (spec.doc.len > 0) {
        try buf.writer.print("\n\n{s}", .{spec.doc});
    }
    return .{
        .text = try buf.toOwnedSlice(),
        .range = txt.wordRangeAt(text, pos) orelse .{
            .start = pos,
            .end = .{
                .line = pos.line,
                .character = pos.character + @as(u32, @intCast(name.len)),
            },
        },
    };
}

/// same with your `opts`
///   keeps sig lookup from thrashing cache with defaults
fn renderDefinitionOpts(
    alloc: std.mem.Allocator,
    name: []const u8,
    type_name: []const u8,
    ws: *Workspace,
    file_id: FileId,
    opts: pipeline.BuildOptions,
) ![]const u8 {
    if (try ws.fnSigOpts(alloc, file_id, name, opts)) |sig| {
        return common.formatSig(alloc, name, sig);
    }
    if (type_name.len > 0 and std.mem.startsWith(u8, type_name, "fn(")) {
        return alloc.print("fn {s}{s}", .{ name, type_name[2..] });
    }
    if (type_name.len > 0)
        return alloc.dupe(u8, type_name);
    return alloc.dupe(u8, name);
}

test "workspace hover shows record field values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const source =
        \\let t = {
        \\  name = "me",
        \\}
        \\t
    ;
    const id = try ws.open("<test>", source, .{});
    const query_opts: pipeline.BuildOptions = .{
        .install_debug_info = false,
        .test_mode = false,
    };

    var hov = try ws.hover(alloc, id, .{ .line = 4, .character = 1 }, query_opts);
    try std.testing.expect(hov != null);
    defer if (hov) |*h| h.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "{name: string = \"me\"}") != null);
}

test "workspace hover over bare fn definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const query_opts: pipeline.BuildOptions = .{
        .install_debug_info = false,
        .test_mode = true,
    };

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "let x = 42\n\nfn say_hi(name) do\n  print(\"hello \" + name)\nend\n", .{});
    _ = try ws.inspectDetailed(alloc, id, query_opts);

    var hov = try ws.hover(alloc, id, .{ .line = 3, .character = 5 }, query_opts);
    defer if (hov) |*h| h.deinit(alloc);
    try std.testing.expect(hov != null);
}

test "workspace hover over baselib module name shows member card" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const query_opts: pipeline.BuildOptions = .{
        .install_debug_info = false,
        .test_mode = true,
    };

    var vm = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();
    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "print(math.floor(1.5))\n", .{});
    var hov = try ws.hover(alloc, id, .{ .line = 1, .character = 8 }, query_opts);
    defer if (hov) |*h| h.deinit(alloc);
    try std.testing.expect(hov != null);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "module `math`") != null);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "numeric math") != null);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "math.floor(x: number) -> number") != null);
}

test "workspace hover over qualified member prefers its module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const query_opts: pipeline.BuildOptions = .{
        .install_debug_info = false,
        .test_mode = true,
    };

    var vm = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();
    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "print(math.floor(1.5))\n", .{});
    // `floor` exists in several modules; the `math.` qualifier must win
    // over the unqualified first match (`number.floor`)
    var hov = try ws.hover(alloc, id, .{ .line = 1, .character = 13 }, query_opts);
    defer if (hov) |*h| h.deinit(alloc);
    try std.testing.expect(hov != null);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "math.floor(x: number) -> number") != null);
}
