const std = @import("std");
const lsp = @import("lsp");
const revo = @import("revo");

const T = lsp.types;
const lexer = revo.lang.lexer;
const ws = revo.lang.workspace;

const keywords = lexer.TokenType.of_string.keys();

/// complete identifiers at cursor position in `text`
pub fn completions(
    vm: *revo.VM,
    workspace: *ws.Workspace,
    arena: std.mem.Allocator,
    file_id: ws.FileId,
    text: []const u8,
    cursor_off: usize,
) !T.completion.Result {
    // scan backward from cursor to find prefix start
    var start = cursor_off;
    while (start > 0 and lexer.isIdentContinue(text[start - 1])) start -= 1;
    const prefix = text[start..cursor_off];

    // check for '.' before the prefix (field completion)
    const dot_target = if (start > 0 and text[start - 1] == '.') blk: {
        var dot_start = start - 1;
        while (dot_start > 0 and lexer.isIdentContinue(text[dot_start - 1])) dot_start -= 1;
        break :blk text[dot_start .. start - 1];
    } else null;

    var items = std.ArrayList(T.completion.Item).initCapacity(arena, 128) catch {
        return T.completion.Result{ .completion_items = &.{} };
    };

    if (dot_target) |target| {
        try addFieldCompletions(vm, arena, &items, target, prefix);
    } else {
        try addGeneralCompletions(vm, workspace, arena, &items, prefix, file_id);
    }

    return T.completion.Result{ .completion_items = items.items };
}

/// completions for fields of a table or struct (after a dot)
fn addFieldCompletions(
    vm: *revo.VM,
    arena: std.mem.Allocator,
    items: *std.ArrayList(T.completion.Item),
    target: []const u8,
    prefix: []const u8,
) !void {
    const target_atom = vm.internAtom(target) catch return;
    const val = vm.globals.get(target_atom) orelse return;
    if (val.isTable()) {
        const table = try vm.tables.get(val.asTable().?);
        var kit = table.hash_entries.keyIterator();
        while (kit.next()) |key| {
            if (key.isAtom()) {
                const name = vm.atomName(key.asAtom().?);
                if (std.mem.startsWith(u8, name, prefix)) {
                    items.append(arena, .{
                        .label = name,
                        .kind = .Field,
                    }) catch return;
                }
            }
        }
    }
}

/// completions from keywords, globals, and document symbols
fn addGeneralCompletions(
    vm: *revo.VM,
    workspace: *ws.Workspace,
    arena: std.mem.Allocator,
    items: *std.ArrayList(T.completion.Item),
    prefix: []const u8,
    file_id: ws.FileId,
) !void {
    // keywords
    inline for (keywords) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) {
            items.append(arena, .{ .label = kw, .kind = .Keyword }) catch return;
        }
    }

    // globals from vm (stdlib + user)
    {
        var git = vm.globals.iterator();
        while (git.next()) |entry| {
            const name = vm.atomName(entry.key_ptr.*);
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const kind: ?T.completion.Item.Kind = if (entry.value_ptr.isFunction())
                .Function
            else if (entry.value_ptr.isTable())
                .Module
            else if (entry.value_ptr.isStructType())
                .Struct
            else
                .Variable;

            var insert_text: ?[]const u8 = null;
            var insert_text_format: ?T.InsertTextFormat = null;
            var detail: ?[]const u8 = null;
            var doc_copy: ?[]const u8 = null;

            if (entry.value_ptr.isFunction()) {
                if (revo.std_lib.api.find(name)) |spec| {
                    doc_copy = if (spec.doc.len > 0) (arena.dupe(u8, spec.doc) catch null) else null;
                    // detail: name(p1: t1, p2: t2) -> ret
                    {
                        var buf = std.Io.Writer.Allocating.init(arena);
                        try buf.writer.print("{s}(", .{name});
                        for (spec.params, 0..) |p, i| {
                            if (i > 0) try buf.writer.print(", ", .{});
                            try buf.writer.print("{s}: {s}", .{ p[0], p[1] });
                        }
                        try buf.writer.print(")", .{});
                        if (spec.ret.len > 0)
                            try buf.writer.print(" -> {s}", .{spec.ret});
                        detail = buf.written();
                    }
                    // insertText: name(${1:p1}, ${2:p2}) or name()
                    if (spec.params.len > 0) {
                        var sbuf = std.Io.Writer.Allocating.init(arena);
                        try sbuf.writer.print("{s}(", .{name});
                        for (spec.params, 1..) |p, i| {
                            if (i > 1) try sbuf.writer.print(", ", .{});
                            try sbuf.writer.writeByte('$');
                            try sbuf.writer.writeByte('{');
                            try sbuf.writer.print("{d}", .{i});
                            try sbuf.writer.writeByte(':');
                            try sbuf.writer.print("{s}", .{p[0]});
                            try sbuf.writer.writeByte('}');
                        }
                        try sbuf.writer.print(")", .{});
                        insert_text = sbuf.written();
                        insert_text_format = .Snippet;
                    } else {
                        insert_text = try std.fmt.allocPrint(arena, "{s}()", .{name});
                        insert_text_format = .PlainText;
                    }
                }
            }

            items.append(arena, .{
                .label = name,
                .kind = kind,
                .detail = detail,
                .insertText = insert_text,
                .insertTextFormat = insert_text_format,
                .documentation = if (doc_copy) |d|
                    .{ .markup_content = .{ .kind = .markdown, .value = d } }
                else
                    null,
            }) catch return;
        }
    }

    // document-local symbols (from inspect cache)
    {
        var analysis = workspace.inspectDetailed(arena, file_id, .{}) catch return;
        defer analysis.deinit(arena);
        for (analysis.symbols) |sym| {
            if (!std.mem.startsWith(u8, sym.name, prefix)) continue;
            const kind: T.completion.Item.Kind = switch (sym.kind) {
                .function => .Function,
                .struct_type => .Struct,
                .type_alias => .Class,
                .binding => .Variable,
            };
            // avoid exact dupes with globals (prefer local)
            var duped = false;
            var git = vm.globals.iterator();
            while (git.next()) |entry| {
                if (std.mem.eql(u8, sym.name, vm.atomName(entry.key_ptr.*))) {
                    duped = true;
                    break;
                }
            }
            if (!duped) {
                const label = try arena.dupe(u8, sym.name);

                var insert_text: ?[]const u8 = null;
                var insert_text_format: ?T.InsertTextFormat = null;
                var detail: ?[]const u8 = null;

                if (kind == .Function) {
                    if (try workspace.fnSig(arena, file_id, sym.name)) |sig| {
                        // detail: name(p1: t1, p2: t2) -> ret
                        {
                            var buf = std.Io.Writer.Allocating.init(arena);
                            try buf.writer.print("{s}(", .{sym.name});
                            for (sig.params, 0..) |p, i| {
                                if (i > 0) try buf.writer.print(", ", .{});
                                try buf.writer.print("{s}: {s}", .{ p.name, p.type_name });
                            }
                            try buf.writer.print(")", .{});
                            if (sig.return_type.len > 0)
                                try buf.writer.print(" -> {s}", .{sig.return_type});
                            detail = buf.written();
                        }
                        // insertText: name(${1:p1}, ${2:p2}) or name()
                        if (sig.params.len > 0) {
                            var sbuf = std.Io.Writer.Allocating.init(arena);
                            try sbuf.writer.print("{s}(", .{sym.name});
                            for (sig.params, 1..) |p, i| {
                                if (i > 1) try sbuf.writer.print(", ", .{});
                                try sbuf.writer.writeByte('$');
                                try sbuf.writer.writeByte('{');
                                try sbuf.writer.print("{d}", .{i});
                                try sbuf.writer.writeByte(':');
                                try sbuf.writer.print("{s}", .{p.name});
                                try sbuf.writer.writeByte('}');
                            }
                            try sbuf.writer.print(")", .{});
                            insert_text = sbuf.written();
                            insert_text_format = .Snippet;
                        } else {
                            insert_text = try std.fmt.allocPrint(arena, "{s}()", .{sym.name});
                            insert_text_format = .PlainText;
                        }
                    }
                }

                items.append(arena, .{
                    .label = label,
                    .kind = kind,
                    .detail = detail,
                    .insertText = insert_text,
                    .insertTextFormat = insert_text_format,
                }) catch return;
            }
        }
    }
}
