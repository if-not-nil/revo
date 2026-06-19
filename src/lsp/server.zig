const std = @import("std");
const builtin = @import("builtin");

const lsp = @import("lsp");
const T = lsp.types;
const revo = @import("revo");
const lang = revo.lang;
const Workspace = lang.Workspace;

const completion = @import("completion.zig");

pub fn main(init: std.process.Init) !void {
    try runLsp(init.gpa, init.io, .script, "");
}

pub fn runLsp(gpa: std.mem.Allocator, io: std.Io, mode: revo.lang.RunMode, project_root: []const u8) !void {
    var read_buf: [1024]u8 = undefined;
    var stdio = lsp.Transport.Stdio.init(&read_buf, .stdin(), .stdout());

    var handler = try Handler.init(gpa, &stdio.transport, io, mode, project_root);
    handler.ws.attachVm(&handler.vm);
    defer handler.deinit();

    try lsp.basic_server.run(io, gpa, &stdio.transport, &handler, std.log.err);
}

//
// handler
//

/// per-session state,,, workspace, vm, uri<->fileid
const Handler = struct {
    alloc: std.mem.Allocator,
    transport: *lsp.Transport,
    io: std.Io,
    // ws holds a reference to vm
    ws: Workspace.Workspace,
    vm: revo.VM,
    enc: lsp.offsets.Encoding = .@"utf-16", // client preference
    uri_to_file: std.StringHashMapUnmanaged(Workspace.FileId) = .empty, // uri -> ws id
    file_to_uri: std.AutoHashMapUnmanaged(Workspace.FileId, []const u8) = .empty, // ws id -> uri
    deinited: bool = false,
    project: lang.Project = .{ .mode = .script, .root = "" },

    fn init(alloc: std.mem.Allocator, transport: *lsp.Transport, io: std.Io, mode: revo.lang.RunMode, project_root: []const u8) !Handler {
        var vm = try revo.VM.init(.{ .alloc = alloc, .io = io });
        errdefer vm.deinit();
        var workspace = try Workspace.Workspace.init(alloc);
        errdefer workspace.deinit();
        return .{
            .alloc = alloc,
            .transport = transport,
            .io = io,
            .ws = workspace,
            .vm = vm,
            .project = .{ .mode = mode, .root = project_root },
        };
    }

    /// free in orderof owned uri strings, then workspace, then vm
    fn deinit(h: *Handler) void {
        h.cleanup();
    }

    fn cleanup(h: *Handler) void {
        if (h.deinited) return;
        h.deinited = true;
        // free uri strings from uri_to_file keys (file_to_uri values alias them)
        {
            var it = h.uri_to_file.iterator();
            while (it.next()) |entry| h.alloc.free(entry.key_ptr.*);
        }
        h.uri_to_file.deinit(h.alloc);
        h.file_to_uri.deinit(h.alloc);
        h.ws.deinit();
        h.vm.deinit();
    }

    /// track document uri<->fileid pair (dupes uri)
    fn registerDoc(h: *Handler, uri: []const u8, file_id: Workspace.FileId) !void {
        const u = try h.alloc.dupe(u8, uri);
        errdefer h.alloc.free(u);
        try h.uri_to_file.put(h.alloc, u, file_id);
        try h.file_to_uri.put(h.alloc, file_id, u);
    }

    /// remove uri from both maps and free key string
    fn unregisterDoc(h: *Handler, uri: []const u8) void {
        const kv = h.uri_to_file.fetchRemove(uri) orelse return;
        h.alloc.free(kv.key);
        _ = h.file_to_uri.remove(kv.value);
    }

    /// advertise supported features and pick position encoding from client prefs
    pub fn initialize(h: *Handler, _: std.mem.Allocator, params: T.InitializeParams) T.InitializeResult {
        // clients first known pos encoding
        if (params.capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |pe| {
                h.enc = switch (pe) {
                    .@"utf-8" => .@"utf-8",
                    .@"utf-16" => .@"utf-16",
                    .@"utf-32" => .@"utf-32",
                    .custom_value => continue,
                };
                break;
            }
        }
        const caps = T.ServerCapabilities{
            .positionEncoding = switch (h.enc) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            },
            .textDocumentSync = .{
                .text_document_sync_options = .{
                    .openClose = true,
                    .change = .Full,
                },
            },
            .definitionProvider = .{ .bool = true },
            .hoverProvider = .{ .bool = true },
            .referencesProvider = .{ .bool = true },
            .documentSymbolProvider = .{ .bool = true },
            .workspaceSymbolProvider = .{ .bool = true },
            .completionProvider = .{ .triggerCharacters = &.{"."} },
            .signatureHelpProvider = T.SignatureHelp.Options{
                .triggerCharacters = &.{},
            },
        };
        // sanity check in debug builds
        if (builtin.mode == .Debug) {
            lsp.basic_server.validateServerCapabilities(Handler, caps);
        }
        return .{
            .serverInfo = .{ .name = "revolt", .version = "0.0.1" },
            .capabilities = caps,
        };
    }

    /// TODO: client notification
    pub fn initialized(_: *Handler, _: std.mem.Allocator, _: T.InitializedParams) void {}

    pub fn shutdown(_: *Handler, _: std.mem.Allocator, _: void) ?void {
        return null;
    }

    /// no reply needed
    /// leaking is actually fine here, but this just prevents a ton of noise
    pub fn exit(h: *Handler, _: std.mem.Allocator, _: void) void {
        h.cleanup();
    }

    /// open a file in the workspace and publish initial diags
    pub fn @"textDocument/didOpen"(h: *Handler, arena: std.mem.Allocator, params: T.TextDocument.DidOpenParams) !void {
        // strip file:// pref for ws api
        const path = if (std.mem.startsWith(u8, params.textDocument.uri, "file://"))
            params.textDocument.uri["file://".len..]
        else
            params.textDocument.uri;
        const id = try h.project.open(&h.ws, path, params.textDocument.text);
        try h.registerDoc(params.textDocument.uri, id);
        try h.publishDiagnostics(arena, params.textDocument.uri, id);
    }

    /// full-document sync; reparse n push updated diagnostics
    pub fn @"textDocument/didChange"(h: *Handler, arena: std.mem.Allocator, params: T.TextDocument.DidChangeParams) !void {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return;
        // full sync; only the last change matters
        const last = params.contentChanges.len - 1;
        const text = switch (params.contentChanges[last]) {
            .text_document_content_change_whole_document => |c| c.text,
            .text_document_content_change_partial => |c| c.text,
        };
        try h.ws.change(file_id, text);
        try h.publishDiagnostics(arena, params.textDocument.uri, file_id);
    }

    /// close the file in ws and drop uri mappings
    pub fn @"textDocument/didClose"(h: *Handler, _: std.mem.Allocator, params: T.TextDocument.DidCloseParams) !void {
        if (h.uri_to_file.get(params.textDocument.uri)) |file_id| {
            h.ws.close(file_id);
        }
        h.unregisterDoc(params.textDocument.uri);
    }

    /// go-to-definition; position is 1-based inside workspace, 0-based otw
    pub fn @"textDocument/definition"(h: *Handler, arena: std.mem.Allocator, params: T.Definition.Params) !?T.Definition.Result {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const ws_pos = add1(params.position);
        const loc = try h.ws.definition(arena, file_id, ws_pos, .{}) orelse return null;
        const uri = h.file_to_uri.get(loc.file_id) orelse return null;
        return T.Definition.Result{ .definition = .{ .location = .{
            .uri = uri,
            .range = .{ .start = sub1(loc.range.start), .end = sub1(loc.range.end) },
        } } };
    }

    /// hover info at position
    pub fn @"textDocument/hover"(h: *Handler, arena: std.mem.Allocator, params: T.Hover.Params) !?T.Hover {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const ws_pos = add1(params.position);
        const hov = try h.ws.hover(arena, file_id, ws_pos, .{}) orelse return null;
        return T.Hover{
            .contents = .{ .markup_content = .{ .kind = .markdown, .value = hov.text } },
            .range = .{ .start = sub1(hov.range.start), .end = sub1(hov.range.end) },
        };
    }

    /// signature help at cursor position
    pub fn @"textDocument/signatureHelp"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.SignatureHelp.Params,
    ) !?T.SignatureHelp {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const ws_pos = add1(params.position);
        const sig = try h.ws.signatureHelp(arena, file_id, ws_pos, .{}) orelse return null;
        // sig is arena-allocated; arena cleans up after handler returns

        // build the label like `fn_name(param1: t1, param2: t2): ret`
        var label = try std.ArrayList(u8).initCapacity(arena, 64);
        try label.appendSlice(arena, sig.name);
        try label.append(arena, '(');
        for (sig.params, 0..) |p, i| {
            if (i > 0) try label.appendSlice(arena, ", ");
            try label.appendSlice(arena, p.name);
            if (p.type_name.len > 0) {
                try label.appendSlice(arena, ": ");
                try label.appendSlice(arena, p.type_name);
            }
        }
        try label.append(arena, ')');
        if (sig.return_type.len > 0) {
            try label.appendSlice(arena, ": ");
            try label.appendSlice(arena, sig.return_type);
        }
        const label_str = try label.toOwnedSlice(arena);

        // param offsets into label
        var params_list = try std.ArrayList(T.SignatureHelp.Signature.Parameter).initCapacity(arena, sig.params.len);
        var pos: u32 = @as(u32, @intCast(sig.name.len)) + 1; // after `(`
        for (sig.params) |p| {
            const start = pos;
            // skip past `name: type` or just `name`
            pos += @as(u32, @intCast(p.name.len));
            if (p.type_name.len > 0) pos += 2 + @as(u32, @intCast(p.type_name.len));
            params_list.appendAssumeCapacity(.{
                .label = .{ .tuple_1 = .{ start, pos } },
                .documentation = null,
            });
            pos += 2; // skip ", "
        }

        // documentation as plain string (dupe before sig.deinit)
        const doc_text = if (sig.doc) |d| try arena.dupe(u8, d) else null;
        const doc = if (doc_text) |d| T.Documentation{ .string = d } else null;

        // allocate signatures array on arena (not stack)
        const signatures = try arena.alloc(T.SignatureHelp.Signature, 1);
        signatures[0] = .{
            .label = label_str,
            .documentation = doc,
            .parameters = try params_list.toOwnedSlice(arena),
            .activeParameter = sig.active_param,
        };

        return T.SignatureHelp{
            .signatures = signatures,
            .activeSignature = 0,
            .activeParameter = sig.active_param,
        };
    }

    /// get all refs to the symbol at position
    pub fn @"textDocument/references"(h: *Handler, arena: std.mem.Allocator, params: T.reference.Params) !?[]const T.Location {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const ws_pos = add1(params.position);
        const refs = try h.ws.references(arena, file_id, ws_pos, .{});
        defer arena.free(refs);

        // map workspace file ids back to uris
        var out = try std.ArrayList(T.Location).initCapacity(arena, refs.len);
        for (refs) |ref| {
            const uri = h.file_to_uri.get(ref.file_id) orelse continue;
            out.appendAssumeCapacity(.{
                .uri = uri,
                .range = .{ .start = sub1(ref.range.start), .end = sub1(ref.range.end) },
            });
        }
        const result = try out.toOwnedSlice(arena);
        return @as(?[]const T.Location, result);
    }

    /// list all symbols in a document
    pub fn @"textDocument/documentSymbol"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.DocumentSymbol.Params,
    ) !?T.DocumentSymbol.Result {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const syms = try h.ws.documentSymbols(arena, file_id, .{});
        defer arena.free(syms);
        var list = try std.ArrayList(T.SymbolInformation).initCapacity(arena, syms.len);
        for (syms) |sym| {
            list.appendAssumeCapacity(.{
                .name = sym.name,
                .kind = symbolKindToLsp(sym.kind),
                .location = .{
                    .uri = params.textDocument.uri,
                    .range = .{ .start = sub1(sym.range.start), .end = sub1(sym.range.end) },
                },
            });
        }
        return T.DocumentSymbol.Result{ .symbol_informations = try list.toOwnedSlice(arena) };
    }

    /// complete identifiers at cursor position
    pub fn @"textDocument/completion"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.completion.Params,
    ) !?T.completion.Result {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const ws_pos = add1(params.position);
        const cursor_off = positionToOffset(snap.text, ws_pos) orelse return null;
        return @as(?T.completion.Result, try completion.completions(&h.vm, &h.ws, arena, file_id, snap.text, cursor_off));
    }

    /// search workspace-wide by query str
    pub fn @"workspace/symbol"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.workspace.Symbol.Params,
    ) !?T.workspace.Symbol.Result {
        const syms = try h.ws.findSymbols(arena, params.query);
        defer arena.free(syms);
        var list = try std.ArrayList(T.SymbolInformation).initCapacity(arena, syms.len);
        for (syms) |sym| {
            const uri = h.file_to_uri.get(sym.file_id) orelse continue;
            list.appendAssumeCapacity(.{
                .name = params.query,
                .kind = .Variable,
                .location = .{
                    .uri = uri,
                    .range = .{ .start = sub1(sym.range.start), .end = sub1(sym.range.end) },
                },
            });
        }
        return T.workspace.Symbol.Result{ .symbol_informations = try list.toOwnedSlice(arena) };
    }

    /// log unexpected client responses
    pub fn onResponse(_: *Handler, _: std.mem.Allocator, response: lsp.JsonRPCMessage.Response) void {
        std.log.warn("unexpected client response id={?}", .{response.id});
    }

    /// push textDocument/publishDiagnostics notification for a file
    fn publishDiagnostics(
        h: *Handler,
        arena: std.mem.Allocator,
        uri: []const u8,
        file_id: Workspace.FileId,
    ) !void {
        const diag = try h.ws.diagnostics(arena, file_id, .{});
        if (diag) |err| {
            defer lang.deinitError(arena, err);
            // extract the report from whichever phase produced it
            const report = switch (err) {
                .parse => |f| f.report,
                .expand => |f| f.report,
                .lower => |f| f.report,
                .semantic => |f| f.report,
            };
            const lsp_diags = try reportToDiags(arena, report);
            try h.transport.writeNotification(
                h.io,
                arena,
                "textDocument/publishDiagnostics",
                T.publish_diagnostics.Params,
                .{
                    .uri = uri,
                    .diagnostics = lsp_diags,
                },
                .{},
            );
        } else {
            // clear previous diags
            try h.transport.writeNotification(h.io, arena, "textDocument/publishDiagnostics", T.publish_diagnostics.Params, .{
                .uri = uri,
                .diagnostics = &.{},
            }, .{});
        }
    }
};

//
// helpers
//

/// convert a diag report into lsp diag objects
fn reportToDiags(arena: std.mem.Allocator, report: lang.diagnostic.Report) ![]T.Diagnostic {
    const source = report.source orelse "";
    if (report.parts.len == 0) return arena.alloc(T.Diagnostic, 0);
    var out = try std.ArrayList(T.Diagnostic).initCapacity(arena, report.parts.len);

    // only span parts carry position info
    for (report.parts) |part| {
        if (part != .span) continue;
        const sp = part.span;
        out.appendAssumeCapacity(.{
            .range = .{
                .start = offsetToLspPos(source, sp.span.start),
                .end = offsetToLspPos(source, sp.span.end),
            },
            .severity = switch (sp.role) {
                .primary => T.Diagnostic.Severity.Error,
                .secondary => T.Diagnostic.Severity.Warning,
                .context => T.Diagnostic.Severity.Information,
                .trace => T.Diagnostic.Severity.Hint,
            },
            .message = if (report.message.len > 0) report.message
            else if (sp.message.len > 0) sp.message
            else "error",
            .source = "revo",
            .tags = &.{},
            .relatedInformation = &.{},
        });
    }

    // no span parts with position; so emit a file-level diagnostic instead
    if (out.items.len == 0) {
        out.appendAssumeCapacity(.{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            .severity = T.Diagnostic.Severity.Error,
            .message = report.message,
            .source = "revo",
            .tags = &.{},
            .relatedInformation = &.{},
        });
    }
    return out.toOwnedSlice(arena);
}

/// walk source bytes to compute 0-based line/col from byte offset
fn offsetToLspPos(text: []const u8, byte_off: usize) T.Position {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;

    while (i < byte_off and i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}

/// lsp (0-based) -> workspace (1-based)
fn add1(p: T.Position) Workspace.Position {
    return .{ .line = p.line + 1, .character = p.character + 1 };
}

/// workspace (1-based) -> lsp (0-based)
fn sub1(p: Workspace.Position) T.Position {
    return .{ .line = p.line - 1, .character = p.character - 1 };
}

/// convert 1-based workspace position to byte offset
fn positionToOffset(text: []const u8, pos: Workspace.Position) ?usize {
    var line: u32 = 1;
    var col: u32 = 1;
    for (text, 0..) |ch, idx| {
        if (line == pos.line and col == pos.character) return idx;
        if (ch == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    if (line == pos.line and col == pos.character) return text.len;
    return null;
}

fn symbolKindToLsp(kind: Workspace.SymbolKind) T.SymbolKind {
    return switch (kind) {
        .binding => .Variable,
        .function => .Function,
        .struct_type => .Struct,
        .type_alias => .Class,
    };
}
