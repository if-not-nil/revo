//! identifier + field completions

const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;

const cst = @import("../cst.zig");
const common = @import("common.zig");
const diagnostic = @import("../diagnostic.zig");
const hir = @import("../hir.zig");
const Lexer = @import("../Lexer.zig");
const pipeline = @import("../pipeline.zig");
const semantic = @import("../semantic.zig");
const type_syntax = @import("../type_syntax.zig");
const types = @import("../compiler/types.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Completion = W.Completion;
const CompletionKind = W.CompletionKind;

const CallSig = struct {
    detail: []const u8,
    insert_text: []const u8,
};

/// `detail` = name(p1: t1, ...) -> ret, `insert_text` = name(${1:p1}, ...)
fn callSignature(
    arena: std.mem.Allocator,
    name: []const u8,
    param_names: []const []const u8,
    param_types: []const []const u8,
    ret: ?[]const u8,
) !CallSig {
    var buf = std.Io.Writer.Allocating.init(arena);
    try buf.writer.print("{s}(", .{name});
    for (param_names, 0..) |n, i| {
        if (i > 0) try buf.writer.print(", ", .{});
        try buf.writer.print("{s}: {s}", .{ n, param_types[i] });
    }
    try buf.writer.print(")", .{});
    if (ret) |r| try buf.writer.print(" -> {s}", .{r});
    const detail = buf.written();

    if (param_names.len == 0) return .{
        .detail = detail,
        .insert_text = try arena.print("{s}()", .{name}),
    };

    var sbuf = std.Io.Writer.Allocating.init(arena);
    try sbuf.writer.print("{s}(", .{name});
    for (param_names, 1..) |n, i| {
        if (i > 1) try sbuf.writer.print(", ", .{});
        try sbuf.writer.writeByte('$');
        try sbuf.writer.writeByte('{');
        try sbuf.writer.print("{d}", .{i});
        try sbuf.writer.writeByte(':');
        try sbuf.writer.print("{s}", .{n});
        try sbuf.writer.writeByte('}');
    }
    try sbuf.writer.print(")", .{});
    return .{ .detail = detail, .insert_text = sbuf.written() };
}

/// complete identifiers at cursor position in `text`
pub fn completions(
    self: *Workspace,
    arena: std.mem.Allocator,
    file_id: FileId,
    text: []const u8,
    cursor_off: usize,
) ![]Completion {
    const vm = self.vm orelse return &.{};

    // scan backward from cursor to find prefix start
    var start = cursor_off;
    while (start > 0 and Lexer.isIdentContinue(text[start - 1])) start -= 1;
    const prefix = text[start..cursor_off];

    // check for '.' before the prefix (field completion)
    const dot_target = if (start > 0 and text[start - 1] == '.') blk: {
        var dot_start = start - 1;
        while (dot_start > 0 and Lexer.isIdentContinue(text[dot_start - 1])) dot_start -= 1;
        break :blk text[dot_start .. start - 1];
    } else null;

    var items = try std.ArrayList(Completion).initCapacity(arena, 128);

    if (dot_target) |target| {
        try addFieldCompletions(self, vm, arena, &items, target, prefix, file_id, text, start - 1);
    } else {
        try addGeneralCompletions(self, vm, arena, &items, prefix, file_id);
    }

    return items.items;
}

/// document-local table fields for dot-completion; true when anything
/// was added (caller skips the untyped import-symbols path then)
fn localFieldCompletions(
    self: *Workspace,
    arena: std.mem.Allocator,
    items: *std.ArrayList(Completion),
    file_id: FileId,
    text: []const u8,
    dot_pos: usize,
    target: []const u8,
    prefix: []const u8,
) bool {
    const t = completionTargetType(self, arena, file_id, text, dot_pos, target) orelse return false;
    if (t.tag != .table) return false;
    const fields = t.tag.table.fields orelse return false;
    var added = false;
    for (fields) |f| {
        if (!std.mem.startsWith(u8, f.name, prefix)) continue;
        const detail = type_syntax.formatTypeOpts(arena, f.field_type, .{}) catch return added;
        items.append(arena, .{
            .label = f.name,
            .kind = .field,
            .detail = detail,
        }) catch return added;
        added = true;
    }
    return added;
}

/// type of a document local, analyzed from the buffer truncated before
/// the incomplete access (which never parses). dep members resolve to
/// any here; the import-symbols path covers those
fn completionTargetType(
    self: *Workspace,
    arena: std.mem.Allocator,
    file_id: FileId,
    text: []const u8,
    dot_pos: usize,
    target: []const u8,
) ?types.TypeInfo {
    const snap = self.snapshot(file_id) orelse return null;
    const truncated = text[0..@min(dot_pos, text.len)];
    const parsed = pipeline.parse(arena, .{ .name = snap.name, .text = truncated }, .{}) catch return null;
    const root = switch (parsed) {
        .ok => |ok| ok.root,
        .err => return null,
    };

    const known_globals = common.getKnownGlobals(self, arena) catch return null;
    var type_map = std.StringHashMap(types.TypeInfo).init(arena);
    var anchor: u8 = 0;
    var dropped_warn: ?diagnostic.Report = null;

    // semantic requires lowered input; truncation may leave this failing
    // , so there may be no type to complete
    const lowered = hir.lower(arena, root) catch return null;
    _ = semantic.analyze(arena, lowered, snap.name, truncated, known_globals, &type_map, null, null, .{
        .ptr = @ptrCast(&anchor),
        .resolveFn = nullResolve,
    }, &dropped_warn) catch return null;

    return type_map.get(target);
}

fn nullResolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) ?[]const u8 {
    return null;
}

/// completions for fields of a table (after a dot); nested
/// receivers stay silent for now
fn addFieldCompletions(
    self: *Workspace,
    vm: *VM,
    arena: std.mem.Allocator,
    items: *std.ArrayList(Completion),
    target: []const u8,
    prefix: []const u8,
    file_id: FileId,
    text: []const u8,
    dot_pos: usize,
) !void {
    const target_atom = vm.internAtom(target) catch return;
    // baselib modules registered as globals
    //   (string, table, math, etc.)
    //
    // : the module is its runtime table PLUS its declared surface
    // , so type-only aliases
    //      (never runtime values)
    //   complete here too
    if (vm.user_globals.get(target_atom)) |val| {
        if (val.tag() == .table) {
            const table = try vm.tables.get(val.asTable().?);
            var hash_it = table.hash.orderedIterator();
            var seen = std.StringHashMapUnmanaged(void){};

            while (hash_it.next()) |entry| {
                if (entry.key.tag() == .atom) {
                    const name = vm.stringValue(entry.key.asAtom().?);
                    if (std.mem.startsWith(u8, name, prefix)) {
                        var doc: ?[]const u8 = null;
                        if (common.baselibSig(name)) |spec| {
                            if (spec.doc.len > 0) doc = spec.doc;
                        }

                        items.append(arena, .{
                            .label = name,
                            .kind = .field,
                            .documentation = doc,
                        }) catch return;
                        seen.put(arena, name, {}) catch return;
                    }
                }
            }
            // declared members the runtime table cannot hold
            // : aliases and any fn missing at runtime
            // . `__` keys stay out
            // , they are not field accesses
            for (revo.baselib.specs.full_specs) |group| {
                for (group) |*spec| {
                    if (spec.head.kind != .namespaced) continue;
                    if (!std.mem.eql(u8, spec.head.module.?, target)) continue;
                    if (std.mem.startsWith(u8, spec.name, "__")) continue;
                    if (!std.mem.startsWith(u8, spec.name, prefix)) continue;
                    if (seen.contains(spec.name)) continue;

                    items.append(arena, .{
                        .label = spec.name,
                        .kind = if (spec.is_type) .class else .field,
                        .documentation = if (spec.doc.len > 0) spec.doc else null,
                    }) catch return;
                    seen.put(arena, spec.name, {}) catch return;
                }
            }
            return;
        }
    }
    // document locals with known table shapes; shadowing a baselib
    // name with a table still completes baselib members above (runtime
    // dispatches on type, not name)
    if (localFieldCompletions(self, arena, items, file_id, text, dot_pos, target, prefix)) return;
    // user-imported modules (e.g. `import "one.rv"` creates a local binding)
    const imported_syms = self.importedModuleSymbols(arena, file_id, target) catch return;
    for (imported_syms) |sym| {
        if (std.mem.startsWith(u8, sym.name, prefix)) {
            items.append(arena, .{
                .label = sym.name,
                .kind = .field,
            }) catch return;
        }
    }
}

/// completions from keywords, globals, and document symbols
fn addGeneralCompletions(
    self: *Workspace,
    vm: *VM,
    arena: std.mem.Allocator,
    items: *std.ArrayList(Completion),
    prefix: []const u8,
    file_id: FileId,
) !void {
    // keywords
    for (Lexer.TokenType.of_string.keys()) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) {
            items.append(arena, .{ .label = kw, .kind = .keyword }) catch return;
        }
    }

    // note:
    //   global type aliases resolve bare but don't complete here yet
    //   ; no baselib group declares one, so there is nothing to cover
    //   . when the first lands, mirror the dot-path union below:
    //     : is_type + global head as .class
    //     , values keep winning same-named collisions

    // globals off the vm, baselib + user
    var global_names = std.StringHashMapUnmanaged(void){};
    {
        var git = vm.user_globals.iterator();
        while (git.next()) |entry| {
            const name = vm.stringValue(entry.key_ptr.*);
            global_names.put(arena, name, {}) catch return;
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const kind: CompletionKind = if (entry.value_ptr.tag() == .function)
                .function
            else if (entry.value_ptr.tag() == .table)
                .module
            else
                .variable;

            var insert_text: ?[]const u8 = null;
            var detail: ?[]const u8 = null;
            var doc_copy: ?[]const u8 = null;

            if (entry.value_ptr.tag() == .function) {
                // findFn skips type-only aliases, so kind is always function
                if (common.baselibSig(name)) |spec| {
                    doc_copy = if (spec.doc.len > 0) (arena.dupe(u8, spec.doc) catch null) else null;
                    const ft = spec.type.kind.function;
                    const names = try arena.alloc([]const u8, ft.params.len);
                    const param_types = try arena.alloc([]const u8, ft.params.len);

                    for (ft.params, 0..) |p, i| {
                        names[i] = p.name_tok.text;
                        var type_buf = std.Io.Writer.Allocating.init(arena);
                        defer type_buf.deinit();
                        if (p.type) |tn| try cst.printCstType(tn, &type_buf.writer);
                        if (p.dots.len == 2) try type_buf.writer.writeAll("...");
                        param_types[i] = try type_buf.toOwnedSlice();
                    }

                    const sig = try callSignature(
                        arena,
                        name,
                        names,
                        param_types,
                        if (ft.ret) |r| blk: {
                            var ret_buf = std.Io.Writer.Allocating.init(arena);
                            defer ret_buf.deinit();
                            try cst.printCstType(r, &ret_buf.writer);
                            break :blk try ret_buf.toOwnedSlice();
                        } else null,
                    );

                    detail = sig.detail;
                    insert_text = sig.insert_text;
                }
            }

            items.append(arena, .{
                .label = name,
                .kind = kind,
                .detail = detail,
                .insert_text = insert_text,
                .documentation = doc_copy,
            }) catch return;
        }
    }

    {
        const entry = self.ensureInspect(arena, file_id, .{}) catch return;
        for (entry.symbols) |sym| {
            if (!std.mem.startsWith(u8, sym.name, prefix)) continue;
            const kind: CompletionKind = switch (sym.kind) {
                .function => .function,
                .type_alias => .class,
                .binding, .param => .variable,
            };
            // avoid exact dupes with globals (prefer local)
            if (!global_names.contains(sym.name)) {
                const label = try arena.dupe(u8, sym.name);

                var insert_text: ?[]const u8 = null;
                var detail: ?[]const u8 = null;

                if (kind == .function) {
                    if (try self.fnSig(arena, file_id, sym.name)) |sig| {
                        const names = try arena.alloc([]const u8, sig.params.len);
                        const param_types = try arena.alloc([]const u8, sig.params.len);
                        for (sig.params, 0..) |p, i| {
                            names[i] = p.name;
                            param_types[i] = if (p.type_name) |ti| try type_syntax.formatTypeOpts(arena, ti, .{}) else "";
                        }
                        const cs = try callSignature(
                            arena,
                            sym.name,
                            names,
                            param_types,
                            if (sig.return_type) |rt| try type_syntax.formatTypeOpts(arena, rt, .{}) else null,
                        );
                        detail = cs.detail;
                        insert_text = cs.insert_text;
                    }
                }

                items.append(arena, .{
                    .label = label,
                    .kind = kind,
                    .detail = detail,
                    .insert_text = insert_text,
                }) catch return;
            }
        }
    }
}

fn expectCompletion(items: []const Completion, label: []const u8, kind: CompletionKind) !void {
    for (items) |it| {
        if (std.mem.eql(u8, it.label, label)) {
            try std.testing.expectEqual(kind, it.kind);
            return;
        }
    }
    std.debug.print("missing completion {s}, had:", .{label});
    for (items) |it| std.debug.print(" [{s}]", .{it.label});
    std.debug.print("\n", .{});
    return error.TestUnexpectedResult;
}

test "baselib dot completion unions runtime table w declared aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();
    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const text = "uri.";
    const id = try ws.open("<test>", text, .{});
    const items = try ws.completions(arena.allocator(), id, text, text.len);
    // Hi is type-only: no runtime key, only a declared spec
    try expectCompletion(items, "Uri", .class);
    // runtime members still come first without dupes
    var decodes: usize = 0;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "decode")) decodes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), decodes);
}
