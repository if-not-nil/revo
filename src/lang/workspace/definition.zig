//! go-to-definition, references, rename validation

const std = @import("std");

const cst = @import("../cst.zig");
const pipeline = @import("../pipeline.zig");
const txt = @import("text.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Position = W.Position;
const Range = W.Range;
const Location = W.Location;

/// go-to-def, which binding does the word at `pos` mean
pub fn definition(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    pos: Position,
    opts: pipeline.BuildOptions,
) !?Location {
    const snap = self.snapshot(id) orelse return null;
    const name = txt.wordAtPosition(snap.text, pos) orelse return null;
    return bestLocation(self, alloc, name, id, pos, opts);
}

/// every reference to a name, here plus all deps
pub fn references(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    pos: Position,
    opts: pipeline.BuildOptions,
) ![]Location {
    const snap = self.snapshot(id) orelse return self.alloc.alloc(Location, 0);
    const name = txt.wordAtPosition(snap.text, pos) orelse return self.alloc.alloc(Location, 0);
    var out = try std.ArrayList(Location).initCapacity(alloc, 4);
    errdefer out.deinit(alloc);

    collectReferencesInFile(self, alloc, id, name, &out, opts);
    const deps_it = try self.dependencyClosure(alloc, id);
    defer alloc.free(deps_it);
    for (deps_it) |dep| collectReferencesInFile(self, alloc, dep, name, &out, opts);
    return out.toOwnedSlice(alloc);
}

/// validate that the word at pos is renameable, returning its range
pub fn prepareRename(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    pos: Position,
    opts: pipeline.BuildOptions,
) !?Range {
    _ = try self.definition(alloc, id, pos, opts) orelse return null;
    const snap = self.snapshot(id) orelse return null;
    return txt.wordRangeAt(snap.text, pos);
}

/// find the best (closest but before cursor) definition of `name`
pub fn bestLocation(
    self: *Workspace,
    alloc: std.mem.Allocator,
    name: []const u8,
    id: FileId,
    pos: Position,
    opts: pipeline.BuildOptions,
) !?Location {
    var best: ?Location = null;
    try pickBestFromFile(self, alloc, id, name, pos, opts, &best);
    if (best != null) return best;

    const deps = try self.dependencyClosure(alloc, id);
    defer alloc.free(deps);
    for (deps) |dep| {
        try pickBestFromFile(self, alloc, dep, name, pos, opts, &best);
        if (best != null) return best;
    }

    return null;
}

/// best def inside one file
fn pickBestFromFile(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    name: []const u8,
    pos: Position,
    opts: pipeline.BuildOptions,
    best: *?Location,
) !void {
    const snap = self.snapshot(id) orelse return;
    const snap_name = snap.name;
    const entry = try self.ensureInspect(alloc, id, opts);
    for (entry.symbols) |sym| {
        if (!std.mem.eql(u8, sym.name, name)) continue;
        if (txt.positionBefore(sym.range.start, pos)) {
            if (best.* == null or txt.positionBefore(best.*.?.range.start, sym.range.start)) {
                best.* = .{
                    .file_id = id,
                    .name = snap_name,
                    .range = sym.range,
                };
            }
        }
    }
}

/// walk cst for `.ident` nodes matching `name`
fn collectReferencesInFile(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    name: []const u8,
    out: *std.ArrayList(Location),
    opts: pipeline.BuildOptions,
) void {
    const snap = self.snapshot(id) orelse return;
    const parsed_entry = self.parsed(id, opts.repl_mode) catch return;
    const parsed = parsed_entry.result;
    const root = switch (parsed) {
        .ok => |r| r.root,
        .err => return,
    };

    var collector = IdentCollector{
        .name = name,
        .out = out,
        .alloc = alloc,
        .file_id = id,
        .snap_name = snap.name,
        .text = snap.text,
    };
    collector.visit(root);
}

const IdentCollector = struct {
    name: []const u8,
    out: *std.ArrayList(Location),
    alloc: std.mem.Allocator,
    file_id: FileId,
    snap_name: []const u8,
    text: []const u8,

    pub fn visit(self: *@This(), node: *const cst.CstNode) void {
        const u = cst.unwrapParen(node) orelse return;
        if (u.kind == .fn_def) {
            for (u.kind.fn_def.params) |p| {
                if (std.mem.eql(u8, p.name_tok.text, self.name)) {
                    const start = txt.offsetToPosition(self.text, p.name_tok.span().start);
                    const end = txt.offsetToPosition(self.text, p.name_tok.span().end);
                    self.out.append(self.alloc, .{
                        .file_id = self.file_id,
                        .name = self.snap_name,
                        .range = .{ .start = start, .end = end },
                    }) catch {};
                }
            }
        }
        if (u.kind == .ident) {
            if (std.mem.eql(u8, u.kind.ident.tok.text, self.name)) {
                const start = txt.offsetToPosition(self.text, node.span.start);
                const end = txt.offsetToPosition(self.text, node.span.end);
                self.out.append(self.alloc, .{
                    .file_id = self.file_id,
                    .name = self.snap_name,
                    .range = .{ .start = start, .end = end },
                }) catch {};
            }
        }
        cst.walkCst(@This(), self, node);
    }
};

test "workspace query surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const source =
        \\const x = 1
        \\x
    ;
    const id = try ws.open("<test>", source, .{});
    const query_opts: pipeline.BuildOptions = .{
        .install_debug_info = false,
        .test_mode = false,
    };

    const syms = try ws.documentSymbols(alloc, id, query_opts);
    defer alloc.free(syms);
    try std.testing.expect(syms.len != 0);
    var found_symbol = false;
    for (syms) |sym| {
        if (std.mem.eql(u8, sym.name, "x")) {
            found_symbol = true;
            break;
        }
    }
    try std.testing.expect(found_symbol);

    const def = try ws.definition(alloc, id, .{ .line = 2, .character = 1 }, query_opts);
    try std.testing.expect(def != null);
    try std.testing.expectEqualStrings("<test>", def.?.name);

    const refs = try ws.references(alloc, id, .{ .line = 2, .character = 1 }, query_opts);
    defer alloc.free(refs);
    try std.testing.expect(refs.len >= 2);

    var hov = try ws.hover(alloc, id, .{ .line = 2, .character = 1 }, query_opts);
    try std.testing.expect(hov != null);
    defer if (hov) |*h| h.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "number") != null);
    try std.testing.expect(std.mem.find(u8, hov.?.text, "```revo") != null);
}
