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
            items.append(arena, .{
                .label = name,
                .kind = kind,
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
                items.append(arena, .{
                    .label = label,
                    .kind = kind,
                }) catch return;
            }
        }
    }
}
