//!
//! welcome to stdlib as data
//!
//! ~ sigs and docs live in `src/std/iface/*.d.rv`
//!   one file per group
//! ~ `#* ... *#` blocks are markdown docs (bare ``` fences for code)
//! ~ `pub declare <head> = <type>` lines are sigs, `pub type N = <type>`
//!   lines are type-only aliases with no impl
//! ~ `#`/`##` lines are editorial comments
//! ~ heads may carry a `[T]` generic suffix
//! ~ any `__` key lands in a metatable automatically
//! ~ zig supplies impls only (`pub const impls: []const api.Impl` per file)
//! ~ each spec stores the whole RHS type once; sig text, variadic-ness,
//!   and core keys derive from it, so new type shapes need no new fields
//!
//! ~ `loadAllSpecs` merges the two at boot
//!   a missing or orphaned impl is a hard error,
//!   so docs can't drift from the runtime
//! ~ the primitive type metatable *is* the module table:
//!   dynamic `x:method()` dispatch gets a single direct `getRaw`,
//!   numeric indexing the one exception via the `__index` native
//!   stashed inside the module table
//!

const std = @import("std");

const revo = @import("../root.zig");
const ast = @import("../lang/ast.zig");
const Data = revo.Data;
const root = @import("root.zig");
const TypeSpec = root.TypeSpec;
const HostFunc = root.HostFunc;

pub const regex_on = @import("build_options").regex;

/// the zig side of one spec: registry key + implementation
pub const Impl = struct {
    name: []const u8,
    f: HostFunc,
};

pub const Group = struct {
    name: []const u8,
    src: []const u8,
    impls: []const Impl,

    fn init(name: []const u8, src: []const u8, impls: []const Impl) Group {
        return .{ .name = name, .src = src, .impls = impls };
    }
};

/// the `re` group is dropped at comptime when regex is off so the
/// mvzr/io chain never reaches targets like freestanding wasm
pub const groups: []const Group = &.{
    Group.init("root", @embedFile("iface/root.d.rv"), @import("root.zig").root_impls),
    Group.init("os", @embedFile("iface/os.d.rv"), @import("root.zig").os_impls),
    Group.init("re", @embedFile("iface/re.d.rv"), if (regex_on) @import("regex.zig").impls else &.{}),
    Group.init("number", @embedFile("iface/number.d.rv"), @import("number.zig").impls),
    Group.init("string", @embedFile("iface/string.d.rv"), @import("string.zig").impls),
    Group.init("table", @embedFile("iface/table.d.rv"), @import("table.zig").impls),
    Group.init("frame", @embedFile("iface/frame.d.rv"), @import("frame.zig").impls),
    Group.init("iter", @embedFile("iface/iter.d.rv"), @import("iter.zig").impls),
    Group.init("math", @embedFile("iface/math.d.rv"), @import("math.zig").impls),
    Group.init("stats", @embedFile("iface/stats.d.rv"), @import("stats.zig").impls),
    Group.init("json", @embedFile("iface/json.d.rv"), @import("json.zig").impls),
    Group.init("csv", @embedFile("iface/csv.d.rv"), @import("csv.zig").impls),
    Group.init("time", @embedFile("iface/time.d.rv"), @import("time.zig").impls),
    Group.init("net", @embedFile("iface/net.d.rv"), @import("net.zig").impls),
    Group.init("http", @embedFile("iface/http.d.rv"), @import("http.zig").impls),
    Group.init("uri", @embedFile("iface/uri.d.rv"), @import("uri.zig").impls),
    Group.init("fs", @embedFile("iface/fs.d.rv"), @import("fs.zig").impls),
    Group.init("revo", @embedFile("iface/revo.d.rv"), @import("revo.zig").impls),
    Group.init("compress", @embedFile("iface/compress.d.rv"), @import("compress.zig").impls),
    Group.init("rng", @embedFile("iface/rng.d.rv"), @import("rng.zig").impls),
    Group.init("argparse", @embedFile("iface/argparse.d.rv"), @import("argparse_std.zig").impls),
};

/// merged, runtime view of the stdlib surface; built by `loadAllSpecs`
pub var full_specs: []const []const FnSpec = &.{};

var permanent_cache: ?[]const []const FnSpec = null;

pub fn loadAllSpecs(caller_alloc: std.mem.Allocator) ![]const []const FnSpec {
    if (permanent_cache) |cached| {
        full_specs = cached;
        return cached;
    }

    const pa = if (revo.is_freestanding) caller_alloc else std.heap.page_allocator;

    var loaded = try std.ArrayList([]const FnSpec).initCapacity(pa, groups.len);
    errdefer {
        for (loaded.items) |g| {
            for (g) |s| s.deinit(pa);
            pa.free(g);
        }
        loaded.deinit(pa);
    }
    for (groups) |ig| {
        // regex-off rows
        //    (and any future all-types group)
        // carry no impls and stay out of every surface instead of erroring
        if (ig.impls.len == 0) continue;
        const specs = try parseGroup(pa, ig.src);
        for (specs, 0..) |*s, i| {
            if (s.is_type) continue;
            var k: usize = 0;

            if (i > 0) for (specs[0..i]) |other| {
                if (other.is_type) continue;
                if (std.mem.eql(u8, other.name, s.name)) k += 1;
            };

            s.f = implFor(ig.impls, s, k) orelse {
                var err_buf = std.Io.Writer.Allocating.init(pa);
                defer err_buf.deinit();
                renderSignature(&err_buf.writer, s.*) catch {};

                std.debug.print("missing {s}\n", .{err_buf.written()});
                @panic("missing an std def");
            };
        }
        for (ig.impls) |imp| {
            if (findSpec(specs, imp.name) == null) return error.StdlibImplUnused;
        }
        try loaded.append(pa, specs);
    }
    const owned = try loaded.toOwnedSlice(pa);
    permanent_cache = owned;
    full_specs = owned;
    return owned;
}

/// permanent cache
/// the cache lives in page_allocator so no debug allocator tracks it
pub fn freeLoadedSpecs(_: std.mem.Allocator, _: []const []const FnSpec) void {}

/// spans of every `pub macro` / `pub proc` decl in one source
/// . span values only
/// , no lifetimes involved
fn collectMacroSpans(alloc: std.mem.Allocator, src: []const u8) ![]ast.Span {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = try revo.lang.parseSourceReport(arena.allocator(), src);

    const tree = switch (parsed) {
        .ok => |node| node,
        .err => return error.IfaceParseFailed,
    };

    const items: []const *const revo.lang.Node = if (tree.expr == .block) tree.expr.block else &.{tree};
    var out = std.ArrayList(ast.Span).empty;
    errdefer out.deinit(alloc);

    for (items) |item| {
        if (item.expr != .decl) continue;
        const d = item.expr.decl;
        if (!d.pub_) continue;

        switch (d.inner.expr) {
            .macro_expr, .proc_macro => try out.append(alloc, item.span),
            else => {},
        }
    }
    return out.toOwnedSlice(alloc);
}

var macro_sources_cache: ?[]const []const u8 = null;

/// source slices of every `pub macro` / `pub proc` across embedded groups
pub fn macroSources(caller_alloc: std.mem.Allocator) ![]const []const u8 {
    if (macro_sources_cache) |cached| return cached;

    const pa = if (revo.is_freestanding) caller_alloc else std.heap.page_allocator;

    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(pa);
    for (groups) |g| {
        // happy path
        //   macro decls need their keyword spelled out, so most
        //   groups skip the parse entirely (prose mentions still parse)
        if (std.mem.indexOf(u8, g.src, "macro") == null and
            std.mem.indexOf(u8, g.src, "proc") == null) continue;
        const spans = try collectMacroSpans(pa, g.src);
        defer pa.free(spans);
        for (spans) |span| try out.append(pa, g.src[span.start..span.end]);
    }
    const owned = try out.toOwnedSlice(pa);
    macro_sources_cache = owned;
    return owned;
}

/// registry key for impl pairing
/// , derived from the head so new heads and new `__` keys work without touching this
/// : `fs.open`, `string:len`
fn headKey(spec: *const FnSpec, buf: []u8) []const u8 {
    return switch (spec.head.kind) {
        .global => spec.name,
        .module => std.fmt.bufPrint(buf, "{s}.{s}", .{ spec.head.module.?, spec.name }) catch spec.name,
        .method => std.fmt.bufPrint(buf, "{s}:{s}", .{ spec.head.target_name.?, spec.name }) catch spec.name,
    };
}

/// impl registered under the full head like `fs.stat` pairs outright
/// otherwise the k-th spec with this name takes the k-th bare-named impl
fn implFor(impls: []const Impl, spec: *const FnSpec, k: usize) ?HostFunc {
    var key_buf: [256]u8 = undefined;
    const head = headKey(spec, &key_buf);
    for (impls) |imp| if (std.mem.eql(u8, imp.name, head)) return imp.f;
    var seen: usize = 0;
    for (impls) |imp| {
        if (!std.mem.eql(u8, imp.name, spec.name)) continue;
        if (seen == k) return imp.f;
        seen += 1;
    }
    return null;
}

fn findSpec(specs: []const FnSpec, impl_name: []const u8) ?*const FnSpec {
    var key_buf: [256]u8 = undefined;
    for (specs) |*s| {
        if (s.is_type) continue;
        if (std.mem.eql(u8, s.name, impl_name)) return s;
        if (std.mem.eql(u8, headKey(s, &key_buf), impl_name)) return s;
    }
    return null;
}

/// first match wins
pub fn find(name: []const u8) ?*const FnSpec {
    for (full_specs) |group| for (group) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    };
    return null;
}

/// first callable match wins
/// ; type-only aliases are not values
pub fn findFn(name: []const u8) ?*const FnSpec {
    for (full_specs) |group| for (group) |*spec| {
        if (spec.is_type) continue;
        if (std.mem.eql(u8, spec.name, name)) return spec;
    };
    return null;
}

/// `fs.open(path: string) -> !table` for fns,
///   the bare head for type-only aliases
/// . computed from the stored type, never stored
/// , so new type shapes render without new code
pub fn renderSignature(w: *std.Io.Writer, spec: FnSpec) !void {
    try renderSignatureInner(w, spec, false);
}

/// head plus `[T]` suffix: `fs.open`, `string:len`, `table.unwrap_err[T]`
fn renderHead(w: *std.Io.Writer, spec: FnSpec, strip_method: bool) !void {
    switch (spec.head.kind) {
        .global => try w.writeAll(spec.name),
        .module => try w.print("{s}.{s}", .{ spec.head.module.?, spec.name }),
        .method => if (strip_method)
            try w.writeAll(spec.name)
        else
            try w.print("{s}:{s}", .{ spec.head.target_name.?, spec.name }),
    }
    if (spec.type_params.len > 0) {
        try w.writeByte('[');
        for (spec.type_params, 0..) |tp, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(tp);
        }
        try w.writeByte(']');
    }
}

/// method-group display
/// : `len(self: string)` instead of `string:len(self: string)`
pub fn renderSignatureStripMethod(w: *std.Io.Writer, spec: FnSpec) !void {
    try renderSignatureInner(w, spec, true);
}

fn renderSignatureInner(w: *std.Io.Writer, spec: FnSpec, strip_method: bool) !void {
    try renderHead(w, spec, strip_method);
    if (spec.is_type) return;
    const f = spec.type.kind.function;
    try w.writeAll("(");

    for (f.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        if (p.optional) try w.writeByte('?');
        try w.writeAll(p.name);
        if (p.type_name) |tn| {
            try w.writeAll(": ");
            try revo.lang.type_serde.printTypeExpr(tn, w);
        }
        if (p.variadic) try w.writeAll("...");
    }
    try w.writeAll(")");
    if (f.return_type) |r| {
        try w.writeAll(" -> ");
        try revo.lang.type_serde.printTypeExpr(r, w);
    }
}

/// `true` when any fn param is variadic; derived from the stored type
pub fn isVariadic(spec: *const FnSpec) bool {
    if (spec.is_type) return false;
    for (spec.type.kind.function.params) |p| if (p.variadic) return true;
    return false;
}

/// metatable key for `__` names, validated at parse time; null otherwise
pub fn coreKey(spec: *const FnSpec) ?revo.core_atoms {
    if (!std.mem.startsWith(u8, spec.name, "__")) return null;
    return std.meta.stringToEnum(revo.core_atoms, spec.name);
}

pub const Kind = enum { global, module, method };

/// who a spec belongs to, derived once from the declare head at parse time
pub const Head = struct {
    kind: Kind,
    module: ?[]const u8 = null,
    target: ?TypeSpec = null,
    /// owned: `table` in `table:len`, for grouping display
    target_name: ?[]const u8 = null,
};

/// one declaration from a `.d.rv` file
pub const FnSpec = struct {
    name: []const u8,
    head: Head,
    type_params: []const []const u8,
    type: *ast.TypeExpr,
    is_type: bool = false,
    doc: []const u8 = "",
    module_doc: []const u8 = "",
    f: HostFunc,

    /// release one spec's owned strings and trees, not the spec struct itself
    /// `module_doc` is borrowed from the docs pass, never freed here
    pub fn deinit(self: *const FnSpec, alloc: std.mem.Allocator) void {
        alloc.free(self.name);

        if (self.head.module) |m| alloc.free(m);
        if (self.head.target_name) |t| alloc.free(t);
        for (self.type_params) |tp| alloc.free(tp);
        alloc.free(self.type_params);

        revo.lang.type_serde.freeTypeExpr(alloc, self.type);
        alloc.free(self.doc);
    }
};

// -- [iface] -----------------------------------------------------------------

/// parse one `.d.rv` group and collect speacks
fn parseGroup(alloc: std.mem.Allocator, src: []const u8) ![]FnSpec {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try revo.lang.parseSourceReport(a, src);
    const root_node = switch (parsed) {
        .ok => |node| node,
        .err => return error.IfaceParseFailed,
    };

    return collectSpecs(alloc, root_node, true);
}

/// the spec surface of a parsed node
pub fn collectSpecs(alloc: std.mem.Allocator, node: *const revo.lang.Node, iface: bool) ![]FnSpec {
    var specs = std.ArrayList(FnSpec).empty;
    errdefer specs.deinit(alloc);

    const items: []const *const revo.lang.Node = if (node.expr != .block) &.{node} else node.expr.block;
    for (items) |item| {
        // method-style `fn math:twice(x)` parses to a bare assign_expr
        // , no decl wrapper
        // - only docgen collects these
        if (item.expr == .assign_expr) {
            if (iface) continue;
            const ae = item.expr.assign_expr;
            if (ae.value.expr != .fn_expr) continue;
            const t = ae.value.expr.fn_expr;
            if (t.doc == null) continue;

            const ix = switch (ae.target.expr) {
                .index => |x| x,
                else => continue,
            };

            if (ix.object.expr != .ident) continue;
            const key: []const u8 = switch (ix.key.expr) {
                .hash => |h| h,
                .ident => |n| n,
                else => continue,
            };

            // stack shell
            // : declSpec clones the tree, nothing borrowed escapes
            var shell = ast.TypeExpr{ .span = item.span, .kind = .{ .function = .{ .params = t.params, .return_type = t.return_type } } };
            const synth = ast.TypeAlias{
                .name = key,
                .name_span = item.span,
                .type_expr = &shell,
                .declare_head = .{ .core = .{ .target = ix.object.expr.ident, .key = key } },
            };

            try specs.append(alloc, try declSpec(alloc, synth, t.doc, false));
            continue;
        }
        if (item.expr != .decl) continue;
        const d = item.expr.decl;
        switch (d.inner.expr) {
            .type_alias => |t| {
                if (d.kind == .declare_decl) {
                    try specs.append(alloc, try declSpec(alloc, t, d.doc orelse t.doc, iface));
                } else if (d.kind == .type_alias_decl and d.pub_) {
                    try specs.append(alloc, try typeSpec(alloc, t, d.doc orelse t.doc));
                } else continue;
            },
            // macros ride along as source via macroSources, never as specs
            .macro_expr, .proc_macro => {},
            .binding => |b| {
                const doc = d.doc orelse b.doc;
                if (iface) continue;
                if (doc == null) continue;
                if (b.target.expr != .ident) continue;
                if (b.value.expr == .fn_expr) {
                    const t = b.value.expr.fn_expr;
                    var shell = ast.TypeExpr{
                        .span = item.span,
                        .kind = .{ .function = .{ .params = t.params, .return_type = t.return_type } },
                    };

                    const synth = ast.TypeAlias{
                        .name = b.target.expr.ident,
                        .name_span = item.span,
                        .type_expr = &shell,
                    };
                    try specs.append(alloc, try declSpec(alloc, synth, doc, false));
                } else {
                    var shell = ast.TypeExpr{ .span = item.span, .kind = .{ .named = "any" } };
                    const synth = ast.TypeAlias{
                        .name = b.target.expr.ident,
                        .name_span = item.span,
                        .type_expr = &shell,
                    };
                    try specs.append(alloc, try declSpecRaw(alloc, synth, doc));
                }
            },
            else => {},
        }
    }
    return specs.toOwnedSlice(alloc);
}

/// `pub type` aliases, type-namespace, never strict, even for fn rhs
fn typeSpec(alloc: std.mem.Allocator, alias: ast.TypeAlias, doc: ?[]const u8) !FnSpec {
    return declSpecInner(alloc, alias, doc, false, true);
}

/// the single way declarations enter a spec
fn declSpec(alloc: std.mem.Allocator, alias: ast.TypeAlias, doc: ?[]const u8, strict: bool) !FnSpec {
    return declSpecInner(alloc, alias, doc, strict, false);
}

fn declSpecInner(alloc: std.mem.Allocator, alias: ast.TypeAlias, doc: ?[]const u8, strict: bool, force_type: bool) !FnSpec {
    // bare member name is shared logic (ast.bareName)
    // ; the parser always produces 2+ segments for module heads
    // , so no length guard here
    const name: []const u8 = ast.bareName(alias);
    var head: Head = .{ .kind = .global };
    if (alias.declare_head) |dh| switch (dh) {
        .module => |segs| {
            head = .{ .kind = .module, .module = try std.mem.join(alloc, ".", segs[0 .. segs.len - 1]) };
        },
        .core => |c| {
            const target = root.typeFromName(c.target) orelse return error.UnknownMethodTarget;
            head = .{ .kind = .method, .target = target, .target_name = c.target };
        },
    };
    errdefer if (head.module) |m| alloc.free(m);

    if (strict and alias.type_expr.kind == .function) {
        for (alias.type_expr.kind.function.params) |p| {
            if (p.type_name == null) return error.IfaceParamNotTyped;
        }
    }

    if (std.mem.startsWith(u8, name, "__")) {
        // a __-name on a target must be a real metatable slot
        // ; bare unknown __names are plain globals (__internal_dotest etc)
        if (std.meta.stringToEnum(revo.core_atoms, name) == null and head.kind != .global) {
            if (head.module) |m| alloc.free(m);
            return error.BadCoreKey;
        }
    }

    const owned_tps = try alloc.alloc([]const u8, alias.declare_tps.len);
    errdefer alloc.free(owned_tps);
    for (alias.declare_tps, owned_tps) |tp, *dst| dst.* = try alloc.dupe(u8, tp);
    errdefer for (owned_tps) |tp| alloc.free(tp);

    const type_tree = try revo.lang.type_serde.cloneTypeExpr(alloc, alias.type_expr);
    errdefer revo.lang.type_serde.freeTypeExpr(alloc, type_tree);

    const is_type = force_type or type_tree.kind != .function;
    var doc_text: []const u8 = "";
    if (is_type) {
        var doc_buf = std.Io.Writer.Allocating.init(alloc);
        defer doc_buf.deinit();
        try doc_buf.writer.writeAll("alias for\n```revo\n");

        try revo.lang.type_serde.printTypeExpr(type_tree, &doc_buf.writer);
        try doc_buf.writer.writeAll("\n```");

        if (doc) |d| {
            try doc_buf.writer.writeAll("\n\n");
            try doc_buf.writer.writeAll(d);
        }

        doc_text = try alloc.dupe(u8, std.mem.trimEnd(u8, doc_buf.written(), "\n"));
    } else if (doc) |d| {
        var doc_buf = std.ArrayList(u8).empty;
        defer doc_buf.deinit(alloc);

        try doc_buf.appendSlice(alloc, d);
        try docFromMarkdown(alloc, &doc_buf);

        doc_text = try alloc.dupe(u8, std.mem.trimEnd(u8, doc_buf.items, "\n"));
    } else {
        doc_text = try alloc.dupe(u8, "");
    }
    errdefer alloc.free(doc_text);

    return .{
        .name = try alloc.dupe(u8, name),
        .head = .{
            .kind = head.kind,
            .module = head.module,
            .target = head.target,
            .target_name = if (head.target_name) |t| try alloc.dupe(u8, t) else null,
        },
        .type_params = owned_tps,
        .type = type_tree,
        .is_type = is_type,
        .doc = doc_text,
        .f = undefined,
    };
}

/// docs-mode const values (`const a = 5` with `#*`)
fn declSpecRaw(alloc: std.mem.Allocator, alias: ast.TypeAlias, doc: ?[]const u8) !FnSpec {
    var doc_text: []const u8 = "";
    if (doc) |d| {
        var doc_buf = std.ArrayList(u8).empty;
        defer doc_buf.deinit(alloc);
        try doc_buf.appendSlice(alloc, d);
        try docFromMarkdown(alloc, &doc_buf);
        doc_text = try alloc.dupe(u8, std.mem.trimEnd(u8, doc_buf.items, "\n"));
    } else {
        doc_text = try alloc.dupe(u8, "");
    }
    errdefer alloc.free(doc_text);

    return .{
        .name = try alloc.dupe(u8, alias.name),
        .head = .{ .kind = .global },
        .type_params = &.{},
        .type = try revo.lang.type_serde.cloneTypeExpr(alloc, alias.type_expr),
        .is_type = true,
        .doc = doc_text,
        .f = undefined,
    };
}

/// docs runs over arbitrary user files
/// : per-file spec failures skip the file
///   , anything else (OOM etc) aborts
pub fn skippableForDocs(err: anyerror) bool {
    return switch (err) {
        error.IfaceParseFailed,
        error.IfaceParamNotTyped,
        error.UnknownMethodTarget,
        error.BadCoreKey,
        error.BadDoc,
        => true,
        else => false,
    };
}

/// markdown is the authoring form; strip fences and dedent the code block
/// so docgen keeps rendering the prose/code shape it already knows
fn docFromMarkdown(alloc: std.mem.Allocator, doc: *std.ArrayList(u8)) !void {
    const raw = try alloc.dupe(u8, doc.items);
    defer alloc.free(raw);
    const fence = std.mem.indexOf(u8, raw, "```") orelse return;
    const code_rest = raw[fence + 3 ..];
    const code_start: usize = if (code_rest.len > 0 and code_rest[0] == '\n') 1 else 0;
    const code_body = code_rest[code_start..];
    const close = std.mem.indexOf(u8, code_body, "```") orelse return error.BadDoc;
    const code = code_body[0..close];
    const prose = std.mem.trimEnd(u8, raw[0..fence], "\n");

    var min_indent: usize = std.math.maxInt(usize);
    {
        var it = std.mem.splitScalar(u8, code, '\n');
        while (it.next()) |l| {
            if (l.len == 0) continue;
            var n: usize = 0;
            while (n < l.len and l[n] == ' ') n += 1;
            if (n < min_indent) min_indent = n;
        }
    }
    if (min_indent == std.math.maxInt(usize)) min_indent = 0;

    doc.clearRetainingCapacity();
    try doc.appendSlice(alloc, prose);
    try doc.appendSlice(alloc, "\n\n");
    var it = std.mem.splitScalar(u8, code, '\n');
    while (it.next()) |l| {
        if (l.len >= min_indent) try doc.appendSlice(alloc, l[min_indent..]);
        if (it.peek() != null) try doc.append(alloc, '\n');
    }
}

// -- [register] --------------------------------------------------------------

/// returns a Data value to anchor the metatable at `target`. the
/// value itself is discarded; only the metatable slot matters
pub const PrototypeFn = fn (target: TypeSpec, vm: *revo.VM) anyerror!revo.Data;

pub fn registerAll(
    vm: *revo.VM,
    spec_groups: []const []const FnSpec,
    prototype: PrototypeFn,
) !void {
    // plain names go in the table, `__` keys in its metatable, so new metamethods dont need no new arms anywhere
    var mod_entries: std.StringHashMapUnmanaged(std.ArrayList(ModEntry)) = .empty;
    var method_metas: std.AutoHashMapUnmanaged(TypeSpec, std.ArrayList(MetaEntry)) = .empty;
    var global_funcs: std.ArrayList(GlobalEntry) = .empty;

    defer {
        var mit = mod_entries.iterator();
        while (mit.next()) |e| e.value_ptr.deinit(vm.runtime.alloc);
        mod_entries.deinit(vm.runtime.alloc);

        var meit = method_metas.iterator();
        while (meit.next()) |e| e.value_ptr.deinit(vm.runtime.alloc);

        method_metas.deinit(vm.runtime.alloc);
        global_funcs.deinit(vm.runtime.alloc);
    }

    for (spec_groups) |specs| {
        for (specs) |spec| {
            if (spec.is_type) continue;
            const head = spec.head;
            const fn_id = try vm.installHost(spec.name, spec.f);
            switch (head.kind) {
                .global => try global_funcs.append(vm.runtime.alloc, .{ .name = spec.name, .fn_id = fn_id }),
                .module => {
                    const gop = try mod_entries.getOrPutValue(vm.runtime.alloc, head.module.?, .empty);
                    try gop.value_ptr.append(vm.runtime.alloc, .{ .name = spec.name, .atom = coreKey(&spec), .fn_id = fn_id });
                },
                // the target module table IS the metatable
                // , so any key lands there directly
                .method => if (coreKey(&spec)) |atom| {
                    const gop = try method_metas.getOrPutValue(vm.runtime.alloc, head.target.?, .empty);
                    try gop.value_ptr.append(vm.runtime.alloc, .{ .atom = atom, .fn_id = fn_id });
                } else {
                    return error.SpecMethodUnplaceable;
                },
            }
        }
    }

    for (global_funcs.items) |gf| try vm.registerGlobal(gf.name, gf.fn_id);

    {
        var it = mod_entries.iterator();
        while (it.next()) |entry| {
            const table_id = try vm.ensureModule(entry.key_ptr.*);
            var has_meta = false;
            for (entry.value_ptr.items) |f| {
                if (f.atom != null) {
                    has_meta = true;
                } else {
                    try vm.putField(table_id, f.name, Data.new.function(f.fn_id));
                }
            }
            if (has_meta) {
                const mt_id = try vm.tables.create();
                for (entry.value_ptr.items) |f| {
                    if (f.atom) |atom| try vm.putInTable(mt_id, @intFromEnum(atom), f.fn_id);
                }
                try vm.setMetatable(Data.new.table(table_id), mt_id);
            }
        }
    }

    {
        // the type metatable for each primitive iS its module table
        // , so a dynamic `x:method()` dispatch gets a single direct `getRaw`
        const primitives = [_]TypeSpec{ .number, .string, .table };
        for (primitives) |target| {
            const module_tid = moduleTableFor(vm, target) orelse continue;
            if (method_metas.get(target)) |metas| {
                for (metas.items) |m| try vm.putInTable(module_tid, @intFromEnum(m.atom), m.fn_id);
            }
            try vm.setMetatable(try prototype(target, vm), module_tid);
        }
    }
}

/// the module table for a primitive target, if one is registered
fn moduleTableFor(vm: *revo.VM, target: TypeSpec) ?revo.memory.TableID {
    const name = target.moduleName() orelse return null;
    const val = vm.stdlib_globals.get(vm.internAtom(name) catch return null) orelse return null;
    return val.asTable();
}

const ModEntry = struct {
    name: []const u8,
    atom: ?revo.core_atoms,
    fn_id: revo.memory.FunctionID,
};
const MetaEntry = struct {
    atom: revo.core_atoms,
    fn_id: revo.memory.FunctionID,
};
const GlobalEntry = struct {
    name: []const u8,
    fn_id: revo.memory.FunctionID,
};

// -- [test] ------------------------------------------------------------------

const testing = @import("std").testing;

test "parseGroup round trip: sig, params, doc, variadic, core key" {
    const src =
        \\# random comment is skipped
        \\#* single-line doc *#
        \\pub declare iter.range = fn(bound: num, rest: num...) -> function
        \\
        \\#*
        \\finds first occurrence
        \\with a second line
        \\*#
        \\pub declare string:__index = fn(self: string, idx: any) -> string
        \\#*
        \\converts value
        \\
        \\```
        \\fizz(1) => 2
        \\```
        \\*#
        \\pub declare num.__call = fn(value: any) -> num
        \\
        \\#* generic suffix *#
        \\pub declare table.unwrap_err[T] = fn(self: {:err, T}) -> T
        \\
        \\#* escaped "quotes" *#
        \\pub declare debug = fn() -> table
        \\
        \\#* optional input *#
        \\pub declare maybe = fn(?opts: table...) -> !string
    ;
    const specs = try parseGroup(testing.allocator, src);
    defer {
        for (specs) |s| s.deinit(testing.allocator);
        testing.allocator.free(specs);
    }
    try testing.expectEqual(@as(usize, 6), specs.len);

    const range = specs[0];
    try testing.expectEqualStrings("range", range.name);
    {
        const sig = try renderAlloc(testing.allocator, range);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("iter.range(bound: num, rest: num...) -> function", sig);
    }
    try testing.expectEqual(@as(usize, 2), range.type.kind.function.params.len);
    try testing.expectEqualStrings("bound", range.type.kind.function.params[0].name);
    try testing.expectEqualStrings("num", range.type.kind.function.params[0].type_name.?.kind.named);
    try testing.expectEqualStrings("rest", range.type.kind.function.params[1].name);
    try testing.expect(range.type.kind.function.params[1].variadic);
    try testing.expectEqualStrings("num", range.type.kind.function.params[1].type_name.?.kind.named);
    try testing.expect(isVariadic(&range));
    try testing.expectEqualStrings("single-line doc", range.doc);

    const idx = specs[1];
    try testing.expectEqualStrings("__index", idx.name);
    try testing.expectEqual(revo.core_atoms.__index, coreKey(&idx).?);
    try testing.expectEqualStrings("finds first occurrence\nwith a second line", idx.doc);

    const call = specs[2];
    {
        const sig = try renderAlloc(testing.allocator, call);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("num.__call(value: any) -> num", sig);
    }
    try testing.expectEqual(revo.core_atoms.__call, coreKey(&call).?);
    try testing.expectEqualStrings("converts value\n\nfizz(1) => 2", call.doc);

    const unwrap_err = specs[3];
    {
        const sig = try renderAlloc(testing.allocator, unwrap_err);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("table.unwrap_err[T](self: {:err, T}) -> T", sig);
    }
    try testing.expectEqualStrings("unwrap_err", unwrap_err.name);
    var ubuf = std.Io.Writer.Allocating.init(testing.allocator);
    defer ubuf.deinit();
    try revo.lang.type_serde.printTypeExpr(unwrap_err.type.kind.function.params[0].type_name.?, &ubuf.writer);
    try testing.expectEqualStrings("{:err, T}", ubuf.written());
    ubuf.clearRetainingCapacity();
    try revo.lang.type_serde.printTypeExpr(unwrap_err.type.kind.function.return_type.?, &ubuf.writer);
    try testing.expectEqualStrings("T", ubuf.written());
    try testing.expect(!isVariadic(&unwrap_err));

    const debug = specs[4];
    {
        const sig = try renderAlloc(testing.allocator, debug);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("debug() -> table", sig);
    }
    try testing.expectEqual(@as(usize, 0), debug.type.kind.function.params.len);
    try testing.expectEqualStrings("escaped \"quotes\"", debug.doc);

    const maybe = specs[5];
    {
        const sig = try renderAlloc(testing.allocator, maybe);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("maybe(?opts: table...) -> !string", sig);
    }
    try testing.expectEqualStrings("opts", maybe.type.kind.function.params[0].name);
    try testing.expect(maybe.type.kind.function.params[0].optional);
    try testing.expect(maybe.type.kind.function.params[0].variadic);
    try testing.expect(isVariadic(&maybe));
    var mbuf = std.Io.Writer.Allocating.init(testing.allocator);
    defer mbuf.deinit();
    try revo.lang.type_serde.printTypeExpr(maybe.type.kind.function.params[0].type_name.?, &mbuf.writer);
    try testing.expectEqualStrings("table", mbuf.written());
}

fn renderAlloc(alloc: std.mem.Allocator, spec: FnSpec) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    try renderSignature(&buf.writer, spec);
    return alloc.dupe(u8, buf.written());
}

test "parseGroup collects pub type as type-only alias" {
    const src =
        \\#* a port number *#
        \\pub type Port = num
        \\
        \\pub declare open = fn(path: string) -> string
        \\
        \\#* handler alias over fn type stays a type, not a callable *#
        \\pub type Handler = fn(x: num) -> num
        \\
        \\#* namespaced alias keeps its head with a bare name *#
        \\pub type uri.Hi = {n: string}
        \\
        \\type Private = num
    ;
    const specs = try parseGroup(testing.allocator, src);
    defer {
        for (specs) |s| s.deinit(testing.allocator);
        testing.allocator.free(specs);
    }
    try testing.expectEqual(@as(usize, 4), specs.len);

    const port = specs[0];
    try testing.expectEqualStrings("Port", port.name);
    try testing.expect(port.is_type);
    var pbuf = std.Io.Writer.Allocating.init(testing.allocator);
    defer pbuf.deinit();
    try revo.lang.type_serde.printTypeExpr(port.type, &pbuf.writer);
    try testing.expectEqualStrings("num", pbuf.written());

    const open = specs[1];
    try testing.expect(!open.is_type);
    {
        const sig = try renderAlloc(testing.allocator, open);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("open(path: string) -> string", sig);
    }

    const handler = specs[2];
    try testing.expectEqualStrings("Handler", handler.name);
    try testing.expect(handler.is_type);
    try testing.expect(handler.type.kind == .function);

    const hi = specs[3];
    try testing.expect(hi.is_type);
    try testing.expectEqualStrings("Hi", hi.name);
    try testing.expect(hi.head.kind == .module);
    try testing.expectEqualStrings("uri", hi.head.module.?);
    {
        const sig = try renderAlloc(testing.allocator, hi);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("uri.Hi", sig);
    }
}

test "collectMacroSpans finds pub macros and procs only" {
    const src =
        \\pub macro ok?! `(%w:expr)` `%w`
        \\pub proc uri.asdf!(m) do m end
        \\macro private! `(%w:expr)` `%w`
        \\pub declare x = fn() -> num
    ;
    const spans = try collectMacroSpans(testing.allocator, src);
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expect(std.mem.indexOf(u8, src[spans[0].start..spans[0].end], "ok?!") != null);
    try testing.expect(std.mem.indexOf(u8, src[spans[1].start..spans[1].end], "uri.asdf!") != null);
}

test "loadAllSpecs pairs every spec with its impl" {
    const loaded = try loadAllSpecs(testing.allocator);
    var count: usize = 0;
    for (full_specs) |g| for (g) |*s| {
        var sig_buf = std.Io.Writer.Allocating.init(testing.allocator);
        defer sig_buf.deinit();
        try renderSignature(&sig_buf.writer, s.*);
        try testing.expect(sig_buf.written().len > 0);
        count += 1;
    };
    try testing.expect(count > 100);
    try testing.expectEqualStrings("floor", find("floor").?.name);
    freeLoadedSpecs(testing.allocator, loaded);
}
