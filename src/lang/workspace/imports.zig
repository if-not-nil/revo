//! import resolution: paths, dep ids, module symbols

const std = @import("std");

const cst = @import("../cst.zig");
const common = @import("common.zig");
const Parser = @import("../Parser.zig");
const pipeline = @import("../pipeline.zig");
const txt = @import("text.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Symbol = W.Symbol;

/// import path to an open file, checking both source dir and project root
pub fn resolveOpenImport(
    self: *Workspace,
    source_name: []const u8,
    raw_path: []const u8,
    mode: pipeline.ProjectMode,
    project_root: []const u8,
) ?FileId {
    if (resolveImportPath(self, source_name, raw_path)) |resolved| {
        defer self.alloc.free(resolved);
        if (self.file_names.get(resolved)) |id| return id;
    }
    if (mode == .project and project_root.len > 0) {
        if (resolveImportPath(self, project_root, raw_path)) |resolved| {
            defer self.alloc.free(resolved);
            if (self.file_names.get(resolved)) |id| return id;
        }
    }
    return null;
}

/// resolve a relative import path to an absolute one; appends .rv if missing
fn resolveImportPath(
    self: *Workspace,
    source_name: []const u8,
    raw_path: []const u8,
) ?[]const u8 {
    const base_dir = std.Io.Dir.path.dirname(source_name) orelse ".";
    // strip leading ./ from relative paths so join produces a clean path
    var clean = raw_path;
    while (clean.len >= 2 and clean[0] == '.' and clean[1] == '/') clean = clean[2..];
    const joined = if (std.Io.Dir.path.isAbsolute(clean))
        self.alloc.dupe(u8, clean) catch return null
    else
        std.Io.Dir.path.join(self.alloc, &.{ base_dir, clean }) catch return null;
    const ext = std.Io.Dir.path.extension(joined);
    if (ext.len != 0) return joined;
    const with_ext = self.alloc.print("{s}.rv", .{joined}) catch {
        self.alloc.free(joined);
        return null;
    };
    self.alloc.free(joined);
    return with_ext;
}

/// given a file and the name of an import binding, return the symbols
/// exported by the imported module. relies on file stem matching the
/// auto-derived import binding name (the common case for bare imports)
pub fn importedModuleSymbols(
    self: *Workspace,
    alloc: std.mem.Allocator,
    file_id: FileId,
    name: []const u8,
) ![]const Symbol {
    const dep_id = resolveDepId(self, alloc, file_id, name) orelse return &.{};
    return symbolsFromDep(self, alloc, dep_id);
}

/// syms off a dep file, caller frees
pub fn symbolsFromDep(self: *Workspace, alloc: std.mem.Allocator, dep_id: FileId) ![]const Symbol {
    const entry = try self.ensureInspect(alloc, dep_id, .{});
    return common.copyFilteredSymbols(alloc, entry.symbols, true);
}

/// TODO: botch. kill commit after e6f877ea when structural tables exist
/// walk asdf of file_id looking for `const <name> = import '<path>'`
/// and return the resolved import path (caller frees)
pub fn findImportPathForBinding(self: *Workspace, alloc: std.mem.Allocator, file_id: FileId, name: []const u8) ?[]const u8 {
    const snap = self.snapshot(file_id) orelse return null;

    // full text
    // use the lazy cached parse
    if (self.parsed(file_id, false) catch null) |entry| {
        if (entry.result == .ok) {
            if (FindImportVisitor.find(entry.result.ok.root, name)) |result| {
                return alloc.dupe(u8, result) catch null;
            }
        }
    }

    // the buffer usually ends mid-access (`mod.<cursor>`)
    //   , which never parses
    //     : retry once without the last line, where imports live
    const stripped = txt.stripLastLine(snap.text);
    if (stripped.len == snap.text.len) return null;

    const parsed = Parser.parseSourceReport(alloc, stripped, .{}) catch return null;
    const root = switch (parsed) {
        .ok => |n| n,
        .err => return null,
    };
    const result = FindImportVisitor.find(root, name) orelse return null;
    return alloc.dupe(u8, result) catch null;
}

const FindImportVisitor = struct {
    target: []const u8,
    result: ?[]const u8,

    fn find(root: *const cst.CstNode, name: []const u8) ?[]const u8 {
        var visitor = FindImportVisitor{ .target = name, .result = null };
        cst.walkCst(FindImportVisitor, &visitor, root);
        return visitor.result;
    }

    pub fn visit(self: *@This(), node: *const cst.CstNode) void {
        if (self.result != null) return;
        const u = cst.unwrapParen(node) orelse return;
        if (u.kind == .decl) {
            const d = u.kind.decl;
            const inner = cst.unwrapParen(d.inner) orelse return;
            if (inner.kind == .binding) {
                const b = inner.kind.binding;
                const bt = cst.unwrapParen(b.target) orelse return;
                if (bt.kind == .ident and std.mem.eql(u8, bt.kind.ident.tok.text, self.target)) {
                    const bv = cst.unwrapParen(b.value) orelse return;
                    if (bv.kind == .import and bv.kind.import.items.len > 0) {
                        self.result = bv.kind.import.items[0].path.text;
                    }
                }
            }
            return;
        }
        // bare `import "path"`: auto-bound name is the path stem
        if (u.kind == .import) {
            for (u.kind.import.items) |item| {
                if (std.mem.eql(u8, autoImportName(item.path.text), self.target)) {
                    self.result = item.path.text;
                }
            }
        }
        cst.walkCst(FindImportVisitor, self, node);
    }
};

/// auto-bound name for a bare `import "path"`, mirroring Parser
fn autoImportName(path: []const u8) []const u8 {
    return std.Io.Dir.path.stem(path);
}

pub fn resolveDepId(
    self: *Workspace,
    alloc: std.mem.Allocator,
    file_id: FileId,
    mod_name: []const u8,
) ?FileId {
    const deps = self.dependencyClosure(alloc, file_id) catch return null;
    defer alloc.free(deps);
    for (deps) |dep_id| {
        const dep_snap = self.snapshot(dep_id) orelse continue;
        if (txt.moduleFileNameMatches(dep_snap.name, mod_name)) return dep_id;
    }

    // fallback: resolve via const binding import path
    const import_path = findImportPathForBinding(self, alloc, file_id, mod_name) orelse return null;
    defer alloc.free(import_path);
    const snap = self.snapshot(file_id) orelse return null;
    const file_entry = self.entryPtr(file_id) catch return null;

    return resolveOpenImportOrOpen(self, snap.name, import_path, .project, file_entry.project_root);
}

/// resolve an import and open the file from disk if not already open, checking
/// both the source dir and project root; returns null if not found or unreadable
pub fn resolveOpenImportOrOpen(
    self: *Workspace,
    source_name: []const u8,
    raw_path: []const u8,
    mode: pipeline.ProjectMode,
    project_root: []const u8,
) ?FileId {
    if (resolveImportPath(self, source_name, raw_path)) |resolved| {
        defer self.alloc.free(resolved);
        if (self.file_names.get(resolved)) |id| return id;
        if (openFromDisk(self, resolved)) |id| return id;
    }
    if (mode == .project and project_root.len > 0) {
        if (resolveImportPath(self, project_root, raw_path)) |resolved| {
            defer self.alloc.free(resolved);
            if (self.file_names.get(resolved)) |id| return id;
            if (openFromDisk(self, resolved)) |id| return id;
        }
    }
    return null;
}

/// read a file from disk and open it in the workspace. requires vm with I/O.
fn openFromDisk(self: *Workspace, path: []const u8) ?FileId {
    const vm = self.vm orelse return null;
    const io = vm.runtime.io;
    const text = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        self.alloc,
        .limited(std.math.maxInt(usize)),
    ) catch return null;

    defer self.alloc.free(text);
    _ = self.open(path, text, .{}) catch return null;
    return self.file_names.get(path);
}
