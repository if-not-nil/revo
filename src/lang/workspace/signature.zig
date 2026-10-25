//! call-site signature help

const std = @import("std");

const common = @import("common.zig");
const pipeline = @import("../pipeline.zig");
const txt = @import("text.zig");
const types = @import("../compiler/types.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Position = W.Position;
const ParamInfo = W.ParamInfo;
const SignatureHelp = W.SignatureHelp;

/// sig help at a call site, params + doc + which arg youre on
pub fn signatureHelp(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    pos: Position,
    opts: pipeline.BuildOptions,
) !?SignatureHelp {
    const snap = self.snapshot(id) orelse return null;
    const call_info = txt.findCallAtPosition(snap.text, pos) orelse return null;

    const def_opt = try self.bestLocation(alloc, call_info.name, id, pos, opts);
    if (def_opt == null) {
        if (common.baselibSig(call_info.name)) |spec| {
            const ft = spec.type.kind.function;
            const name = try alloc.dupe(u8, spec.name);
            errdefer alloc.free(name);

            const params = try alloc.alloc(ParamInfo, ft.params.len);
            errdefer alloc.free(params);

            for (ft.params, 0..) |p, i| {
                // evalBare can hand back shared comptime sentinels, clone em
                const pt: ?types.TypeInfo = if (p.type) |tn| pt: {
                    const t = try types.evalBare(alloc, tn);
                    break :pt try types.clone(t, alloc);
                } else null;
                params[i] = .{
                    .name = try alloc.dupe(u8, p.name_tok.text),
                    .type_name = pt,
                };
            }

            const ret: ?types.TypeInfo = if (ft.ret) |r| ret: {
                const t = try types.evalBare(alloc, r);
                break :ret try types.clone(t, alloc);
            } else null;

            const doc: ?[]const u8 = if (spec.doc.len > 0) try alloc.dupe(u8, spec.doc) else null;
            errdefer if (doc) |d| alloc.free(d);

            return .{
                .name = name,
                .params = params,
                .return_type = ret,
                .doc = doc,
                .active_param = call_info.active_param,
            };
        }
        return null;
    }
    const def = def_opt orelse return null;
    const entry = try self.ensureInspect(alloc, def.file_id, opts);
    const sig = entry.sig_map.get(call_info.name) orelse return null;

    const name_copy = try alloc.dupe(u8, call_info.name);
    errdefer alloc.free(name_copy);
    const params_copy = try alloc.alloc(ParamInfo, sig.params.len);
    errdefer alloc.free(params_copy);

    for (sig.params, 0..) |p, i| {
        params_copy[i] = .{
            .name = try alloc.dupe(u8, p.name),
            .type_name = if (p.type_name) |ti| try types.clone(ti, alloc) else null,
            .optional = p.optional,
        };
    }

    const ret_copy = if (sig.return_type) |rt| try types.clone(rt, alloc) else null;
    const tps_copy = if (sig.type_params_text) |t| try alloc.dupe(u8, t) else null;

    errdefer if (tps_copy) |t| alloc.free(t);
    // docs ride on sem, not the sig, entry borrows em
    const doc_copy: ?[]const u8 =
        if (entry.docs.get(call_info.name)) |d| try alloc.dupe(u8, d) else null;
    errdefer if (doc_copy) |d| alloc.free(d);

    return SignatureHelp{
        .name = name_copy,
        .params = params_copy,
        .return_type = ret_copy,
        .type_params_text = tps_copy,
        .doc = doc_copy,
        .active_param = call_info.active_param,
    };
}
