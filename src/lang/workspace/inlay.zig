//! type + parameter inlay hints

const std = @import("std");

const common = @import("common.zig");

const cst = @import("../cst.zig");
const pipeline = @import("../pipeline.zig");
const txt = @import("text.zig");
const type_syntax = @import("../type_syntax.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Range = W.Range;
const InlayHint = W.InlayHint;

/// type + param hints for a range
pub fn inlayHints(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    range: Range,
    opts: pipeline.BuildOptions,
) ![]InlayHint {
    const snap = self.snapshot(id) orelse return alloc.alloc(InlayHint, 0);
    const entry = try self.ensureInspect(alloc, id, opts);

    var hints: std.ArrayList(InlayHint) = .empty;
    errdefer hints.deinit(alloc);

    for (entry.symbols) |sym| {
        const ti = sym.type_name orelse continue;
        if (ti.tag == .any or ti.tag == .never) continue;
        if (sym.range.end.line < range.start.line or sym.range.start.line > range.end.line) continue;

        const line = txt.sourceLine(snap.text, sym.range.start.line);

        // fn declarations get `-> ret` after the params; aliases fall
        // through to the generic `: type` hint below
        if (ti.tag == .function) {
            const decl_needle = try alloc.print("fn {s}(", .{sym.name});
            defer alloc.free(decl_needle);
            if (std.mem.find(u8, line, decl_needle) != null) {
                if (std.mem.find(u8, line, "->") != null or ti.tag.function.return_type.tag == .any) continue;
                const ret = try type_syntax.formatTypeOpts(alloc, ti.tag.function.return_type, .{});
                defer alloc.free(ret);

                var paren = sym.range.end.character;
                while (paren < line.len and line[paren] != ')') paren += 1;
                if (paren >= line.len) continue;

                try hints.append(alloc, .{
                    .position = .{ .line = sym.range.start.line, .character = paren + 1 },
                    .label = try alloc.print(" -> {s}", .{ret}),
                    .kind = .type,
                });
                continue;
            }
        }

        const tn = try type_syntax.formatTypeOpts(alloc, ti, .{});
        defer alloc.free(tn);
        const needle = try alloc.print(": {s}", .{tn});
        defer alloc.free(needle);
        if (std.mem.find(u8, line, needle) != null) continue;

        try hints.append(alloc, .{
            .position = sym.range.end,
            .label = try alloc.print(": {s}", .{tn}),
            .kind = .type,
        });
    }

    try appendParamHints(self, alloc, &hints, id);

    return hints.toOwnedSlice(alloc);
}

/// local fns via the sig map, baselib globals as fallback
const ParamHintVisitor = struct {
    ws: *Workspace,
    id: FileId,
    hints: *std.ArrayList(InlayHint),
    alloc: std.mem.Allocator,

    pub fn visit(self: *@This(), node: *const cst.CstNode) void {
        switch (node.kind) {
            .call => |c| {
                const cu = cst.unwrapParen(c.callee) orelse return;
                if (cu.kind == .ident and c.args.len > 0) {
                    self.appendCallHints(cu.kind.ident.tok.text, c.args);
                }
            },
            else => {},
        }
        cst.walkCst(@This(), self, node);
    }

    fn appendCallHints(self: *@This(), name: []const u8, args: []const *cst.CstNode) void {
        const names = self.paramNames(name);
        defer self.alloc.free(names);
        for (args, 0..) |arg, i| {
            if (i >= names.len) break;
            self.hints.append(self.alloc, .{
                .position = .{ .line = arg.span.line, .character = arg.span.column },
                .label = names[i],
                .kind = .parameter,
            }) catch return;
        }
    }

    fn paramNames(self: *@This(), name: []const u8) []const []const u8 {
        if (self.ws.inspect_cache.getPtr(self.id)) |cache| {
            if (cache.sig_map.get(name)) |sig| {
                var out = std.ArrayList([]const u8).empty;
                for (sig.params) |p| out.append(self.alloc, p.name) catch {
                    out.deinit(self.alloc);
                    return &.{};
                };
                return out.toOwnedSlice(self.alloc) catch {
                    out.deinit(self.alloc);
                    return &.{};
                };
            }
        }

        if (common.baselibSig(name)) |spec| {
            var out = std.ArrayList([]const u8).empty;
            for (spec.type.kind.function.params) |p| out.append(self.alloc, p.name_tok.text) catch {
                out.deinit(self.alloc);
                return &.{};
            };
            return out.toOwnedSlice(self.alloc) catch {
                out.deinit(self.alloc);
                return &.{};
            };
        }
        return &.{};
    }
};

fn appendParamHints(
    ws: *Workspace,
    alloc: std.mem.Allocator,
    hints: *std.ArrayList(InlayHint),
    id: FileId,
) !void {
    const parsed_entry = ws.parsed(id, false) catch return;
    const parsed = parsed_entry.result;
    const root = switch (parsed) {
        .ok => |r| r.root,
        .err => return,
    };
    var visitor = ParamHintVisitor{ .ws = ws, .id = id, .hints = hints, .alloc = alloc };
    visitor.visit(root);
}
