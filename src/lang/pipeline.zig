/// build @exports[:name] = name
fn buildSetExport(alloc: std.mem.Allocator, span: ast.Span, name: []const u8) !*Node {
    const exports_ref = try allocNode(alloc, span, .{ .ident = "@exports" });
    const key = try allocNode(alloc, span, .{ .hash = name });
    const index = try allocNode(alloc, span, .{ .index = .{ .object = exports_ref, .key = key } });
    const value = try allocNode(alloc, span, .{ .ident = name });
    return allocNode(alloc, span, .{ .assign_expr = .{ .target = index, .value = value } });
}

/// extract exported name from a pub decl or import_stmt
fn pubName(item: *Node) ?[]const u8 {
    return switch (item.expr) {
        .decl => |d| if (d.pub_) switch (d.inner.expr) {
            .binding => |b| if (b.target.expr == .ident) b.target.expr.ident else null,
            // type aliases are compile-time only, not runtime values
            // so they cannot be exported in the runtime exports table
            else => null,
        } else null,
        .import_stmt => |is| if (is.pub_) is.name else null,
        else => null,
    };
}

/// copy a node without its pub_ flag, leaves non-pub nodes unchanged
fn clearPub(item: *Node, alloc: std.mem.Allocator) !*Node {
    return switch (item.expr) {
        .decl => |d| allocNode(alloc, item.span, .{ .decl = .{
            .inner = d.inner,
            .kind = d.kind,
            .pub_ = false,
        } }),
        .import_stmt => |is| allocNode(alloc, item.span, .{ .import_stmt = .{
            .name = is.name,
            .path = is.path,
            .pub_ = false,
        } }),
        else => item,
    };
}

/// wrap AST for module scope: build exports table from pub decls
fn wrapModule(alloc: std.mem.Allocator, root: *Node) !*Node {
    const is_single = root.expr != .block;
    const items: []const *Node = if (is_single) &[_]*Node{root} else root.expr.block;

    // collect pub names for each item, cache so we don't call pubName twice
    var pub_names = try std.ArrayList(?[]const u8).initCapacity(alloc, items.len);
    errdefer pub_names.deinit(alloc);

    var has_pub = false;
    for (items) |item| {
        const name = if (item.expr == .block) blk: {
            for (item.expr.block) |sub| {
                if (pubName(sub) != null) has_pub = true;
            }
            break :blk null;
        } else pubName(item);
        pub_names.appendAssumeCapacity(name);
        if (name != null) has_pub = true;
    }
    if (!has_pub) {
        pub_names.deinit(alloc);
        return root;
    }

    const span = root.span;

    // const @exports = {}
    const exports_ident = try allocNode(alloc, span, .{ .ident = "@exports" });
    const exports_table = try allocNode(alloc, span, .{ .table = &.{} });
    const exports_binding = try allocNode(alloc, span, .{ .binding = .{
        .target = exports_ident,
        .value = exports_table,
    } });
    const exports_decl = try allocNode(alloc, span, .{ .decl = .{
        .inner = exports_binding,
        .kind = .con,
    } });

    var new_items = try std.ArrayList(*Node).initCapacity(alloc, items.len * 2 + 2); // upper bound: each item + export
    try new_items.append(alloc, exports_decl);

    for (items, pub_names.items) |item, maybe_name| {
        if (item.expr == .block) {
            var cleaned = try std.ArrayList(*Node).initCapacity(alloc, item.expr.block.len);
            for (item.expr.block) |sub| {
                if (pubName(sub)) |_| {
                    try cleaned.append(alloc, try clearPub(sub, alloc));
                } else {
                    try cleaned.append(alloc, sub);
                }
            }
            const new_block = try allocNode(alloc, item.span, .{ .block = try cleaned.toOwnedSlice(alloc) });
            new_block.synthetic_block = item.synthetic_block;
            // emit exports AFTER the block so names defined inside are in scope
            try new_items.append(alloc, new_block);
            for (item.expr.block) |sub| {
                if (pubName(sub)) |name| {
                    try new_items.append(alloc, try buildSetExport(alloc, span, name));
                }
            }
        } else if (maybe_name) |name| {
            try new_items.append(alloc, try clearPub(item, alloc));
            try new_items.append(alloc, try buildSetExport(alloc, span, name));
        } else {
            try new_items.append(alloc, item);
        }
    }
    pub_names.deinit(alloc);

    const final_exports = try allocNode(alloc, span, .{ .ident = "@exports" });
    try new_items.append(alloc, final_exports);

    const result = try allocNode(alloc, span, .{ .block = try new_items.toOwnedSlice(alloc) });
    result.synthetic_block = true;
    return result;
}

/// botch, pls FIXME
/// walk AST recursively: any fn_expr whose body contains pub decls
/// gets its body wrapped so calling the closure returns @exports
fn wrapPubFunctions(alloc: std.mem.Allocator, node: *Node) !void {
    switch (node.expr) {
        .fn_expr => |*f| {
            try wrapPubFunctions(alloc, f.body);
            if (bodyHasPub(f.body)) {
                f.body = try wrapModule(alloc, f.body);
            }
        },
        .block => |items| {
            for (items) |item| try wrapPubFunctions(alloc, item);
        },
        .decl => |*d| try wrapPubFunctions(alloc, d.inner),
        .binding => |*b| {
            try wrapPubFunctions(alloc, b.target);
            try wrapPubFunctions(alloc, b.value);
        },
        .if_expr => |*v| {
            try wrapPubFunctions(alloc, v.condition);
            try wrapPubFunctions(alloc, v.then_expr);
            if (v.else_expr) |e| try wrapPubFunctions(alloc, e);
        },
        .unless_expr => |*v| {
            try wrapPubFunctions(alloc, v.condition);
            try wrapPubFunctions(alloc, v.then_expr);
            if (v.else_expr) |e| try wrapPubFunctions(alloc, e);
        },
        .match_expr => |*m| {
            try wrapPubFunctions(alloc, m.subject);
            for (m.arms) |*arm| try wrapPubFunctions(alloc, arm.then);
        },
        .loop_expr => |*l| try wrapPubFunctions(alloc, l.body),
        .for_loop => |*f| try wrapPubFunctions(alloc, f.body),
        .while_loop => |*w| try wrapPubFunctions(alloc, w.body),
        .labeled_block => |*lb| try wrapPubFunctions(alloc, lb.body),
        .return_expr => |v| if (v) |inner| try wrapPubFunctions(alloc, inner),
        .assign_expr => |*a| {
            try wrapPubFunctions(alloc, a.target);
            try wrapPubFunctions(alloc, a.value);
        },
        .compound_assign => |*a| {
            try wrapPubFunctions(alloc, a.target);
            try wrapPubFunctions(alloc, a.value);
        },
        .call => |*c| {
            try wrapPubFunctions(alloc, c.callee);
            for (c.args) |arg| try wrapPubFunctions(alloc, arg);
        },
        .unary => |*u| try wrapPubFunctions(alloc, u.expr),
        .binary => |*b| {
            try wrapPubFunctions(alloc, b.left);
            try wrapPubFunctions(alloc, b.right);
        },
        .and_expr => |ae| {
            try wrapPubFunctions(alloc, ae.left);
            try wrapPubFunctions(alloc, ae.right);
        },
        .or_expr => |ae| {
            try wrapPubFunctions(alloc, ae.left);
            try wrapPubFunctions(alloc, ae.right);
        },
        .field => |*f| try wrapPubFunctions(alloc, f.object),
        .index => |*i| {
            try wrapPubFunctions(alloc, i.object);
            try wrapPubFunctions(alloc, i.key);
        },
        .table => |entries| {
            for (entries) |*e| {
                if (e.key) |k| try wrapPubFunctions(alloc, k);
                try wrapPubFunctions(alloc, e.value);
            }
        },
        .tuple => |items| {
            for (items) |item| try wrapPubFunctions(alloc, item);
        },
        else => {},
    }
}

fn bodyHasPub(node: *Node) bool {
    return switch (node.expr) {
        .block => |items| for (items) |item| {
            if (pubName(item) != null) break true;
        } else false,
        else => pubName(node) != null,
    };
}

fn allocNode(alloc: std.mem.Allocator, span: ast.Span, expr: ast.Expr) !*Node {
    const n = try alloc.create(ast.Node);
    n.* = .{ .span = span, .expr = expr };
    return n;
}

/// walk AST and pre-load imported modules (best-effort, OOM propagates, others
/// are deferred to runtime where the import native fn handles them)
fn preloadImports(vm: *VM, root: *Node, alloc: std.mem.Allocator) !void {
    var inject_nodes = try std.ArrayList(*Node).initCapacity(alloc, 8);
    defer inject_nodes.deinit(alloc);

    var visited = std.StringHashMap(void).init(alloc);
    defer visited.deinit();

    // separate visited for submod macro extraction, keyed by qualified prefix + path
    // so that re-exports through different parents both get extracted
    var visited_sub = std.StringHashMap(void).init(alloc);
    defer visited_sub.deinit();

    try walkAndProcessImports(vm, root, alloc, &inject_nodes, &visited, &visited_sub);

    if (inject_nodes.items.len > 0 and root.expr == .block) {
        const items = root.expr.block;
        var new_items = try std.ArrayList(*Node).initCapacity(alloc, items.len + inject_nodes.items.len);
        for (inject_nodes.items) |n| new_items.appendAssumeCapacity(n);
        for (items) |item| new_items.appendAssumeCapacity(item);
        root.expr.block = try new_items.toOwnedSlice(alloc);
    }
}

fn walkAndProcessImports(
    vm: *VM,
    node: *Node,
    alloc: std.mem.Allocator,
    inject_nodes: *std.ArrayList(*Node),
    visited: *std.StringHashMap(void),
    visited_sub: *std.StringHashMap(void),
) !void {
    switch (node.expr) {
        .block => |items| {
            for (items) |item| try walkAndProcessImports(vm, item, alloc, inject_nodes, visited, visited_sub);
        },
        .import_stmt => |stmt| try processImport(vm, stmt.path, stmt.name, alloc, inject_nodes, visited, visited_sub),
        .decl => |d| try walkAndProcessImports(vm, d.inner, alloc, inject_nodes, visited, visited_sub),
        .binding => |b| try walkAndProcessImports(vm, b.value, alloc, inject_nodes, visited, visited_sub),
        else => {},
    }
}

/// resolve module path matching runtime import resolution
fn resolveModuleFile(vm: *VM, name: []const u8) !?[]const u8 {
    return revo.resolveImportFile(
        vm.runtime.io,
        vm.runtime.alloc,
        name,
        vm.module_dir,
        vm.project_root,
        vm.package_path.items,
    );
}

/// read, parse, and extract macros/procs from a module for compile-time use
/// does NOT compile or cache the module!!! runtime `import` handles that!
/// extraction populates the expander env with qualified names (mod_name.macro!)
fn processImport(
    vm: *VM,
    path: []const u8,
    mod_name: []const u8,
    alloc: std.mem.Allocator,
    inject_nodes: *std.ArrayList(*Node),
    visited: *std.StringHashMap(void),
    visited_sub: *std.StringHashMap(void),
) !void {
    if (visited.contains(path)) return;
    try visited.put(path, {});

    const resolved = try resolveModuleFile(vm, path) orelse return;
    defer vm.runtime.alloc.free(resolved);

    // non-OOM errors are deferred to runtime,,, preload is best-effort
    const source = std.Io.Dir.cwd().readFileAlloc(
        vm.runtime.io,
        resolved,
        alloc,
        std.Io.Limit.unlimited,
    ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return,
    };

    const module_ast = lang.parseSource(alloc, source) catch return;

    extractPubDefs(module_ast, mod_name, alloc, inject_nodes) catch return;
    extractPubImportsOneLevel(vm, module_ast, mod_name, alloc, inject_nodes, visited_sub) catch return;
}

/// extract pub macros and procs from a module AST, qualified with prefix
/// injects them as named nodes into out for the parent scope
fn extractPubDefs(node: *Node, prefix: []const u8, alloc: std.mem.Allocator, out: *std.ArrayList(*Node)) !void {
    switch (node.expr) {
        .block => |items| {
            for (items) |item| try extractPubDefs(item, prefix, alloc, out);
        },
        .decl => |d| {
            if (d.pub_) {
                switch (d.inner.expr) {
                    .macro_expr => |m| {
                        // already-scoped names liek `uri.asdf!` rescope under
                        // the import like bare ones
                        //  `Port` -> `svc.Port`
                        const qualified = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ prefix, ast.bareMacroName(m.name) });
                        const cloned = try allocNode(alloc, d.inner.span, .{ .macro_expr = .{
                            .name = qualified,
                            .pattern = m.pattern,
                            .template = m.template,
                        } });
                        try out.append(alloc, cloned);
                    },
                    .proc_macro => |pm| {
                        if (std.mem.endsWith(u8, pm.name, "!")) {
                            const qualified = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ prefix, ast.bareMacroName(pm.name) });
                            const proc_node = try allocNode(alloc, d.inner.span, .{ .proc_macro = .{
                                .name = qualified,
                                .param = .{ .name = pm.param.name, .name_span = pm.param.name_span },
                                .body = pm.body,
                            } });
                            try out.append(alloc, proc_node);
                        }
                    },
                    .type_alias => |t| {
                        const ta_node = try allocNode(alloc, d.inner.span, .{
                            .type_alias = .{ .name = t.name, .name_span = t.name_span, .type_expr = t.type_expr },
                        });
                        try out.append(alloc, ta_node);
                    },
                    else => {},
                }
            }
            try extractPubDefs(d.inner, prefix, alloc, out);
        },
        else => {},
    }
}

/// extract one level of pub imports;;; loads submods and extracts their macros
/// but does NOT recurse into submod's own pub imports (breaks the inference cycle)
fn extractPubImportsOneLevel(
    vm: *VM,
    node: *Node,
    prefix: []const u8,
    alloc: std.mem.Allocator,
    inject_nodes: *std.ArrayList(*Node),
    visited_sub: *std.StringHashMap(void),
) !void {
    switch (node.expr) {
        .block => |items| {
            for (items) |item| try extractPubImportsOneLevel(vm, item, prefix, alloc, inject_nodes, visited_sub);
        },
        .import_stmt => |stmt| {
            if (stmt.pub_) {
                // key by qualified prefix + path so different parents with same sub-path
                // both get their macros extracted
                const dedup_key = try std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ prefix, stmt.name, stmt.path });
                defer alloc.free(dedup_key);
                if (visited_sub.contains(dedup_key)) return;
                try visited_sub.put(dedup_key, {});

                const sub_prefix = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ prefix, stmt.name });
                defer alloc.free(sub_prefix);

                const resolved = try resolveModuleFile(vm, stmt.path) orelse return;
                defer vm.runtime.alloc.free(resolved);
                const source = try std.Io.Dir.cwd().readFileAlloc(
                    vm.runtime.io,
                    resolved,
                    alloc,
                    std.Io.Limit.unlimited,
                );

                const sub_ast = try lang.parseSource(alloc, source);
                try extractPubDefs(sub_ast, sub_prefix, alloc, inject_nodes);
            }
        },
        .decl => |d| try extractPubImportsOneLevel(vm, d.inner, prefix, alloc, inject_nodes, visited_sub),
        else => {},
    }
}

pub fn build(vm: *VM, source: Source, opts: BuildOptions) !BuildResult {
    var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
    defer arena.deinit();

    // set module_dir from source name so preloadImports can find local modules
    const prev_module_dir = vm.module_dir;
    defer vm.module_dir = prev_module_dir;
    if (source.name) |name| {
        if (std.fs.path.dirname(name)) |dir| {
            vm.module_dir = dir;
        }
    }

    var parsed = switch (try parse(arena.allocator(), source, .{
        .include_stdlib_macros = opts.include_stdlib_macros,
    })) {
        .ok => |ok| ok,
        .err => |failure| {
            var diag = failure;
            if (source.name) |name| diag.report.source_name = name;
            diag.report = try diag.report.copy(vm.runtime.diag_alloc);
            return .{ .err = .{ .parse = diag } };
        },
    };
    // module scope? wrap ast to build exports table from pub decls
    if (opts.module_scope)
        parsed.root = try wrapModule(arena.allocator(), parsed.root);

    // closures with pub decls should return their @exports table
    try wrapPubFunctions(arena.allocator(), parsed.root);

    if (!opts.skip_preload and comptime !revo.is_freestanding)
        preloadImports(vm, parsed.root, arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => revo.pretty.fatal("preload: {s}", .{@errorName(err)}, vm),
        };

    const expand_result = try expandWithVmSource(
        vm,
        arena.allocator(),
        parsed,
        source.name orelse "",
        source.text,
    );

    const expanded = switch (expand_result) {
        .ok => |ok| ok,
        .proc_err, .macro_err => |report| {
            var copied = try report.copy(vm.runtime.diag_alloc);
            copied.source_name = source.name;
            copied.source = source.text;
            return .{ .err = .{ .expand = .{ .report = copied } } };
        },
    };

    var type_annotations = std.AutoHashMap(*const Node, compiler.types.TypeInfo).init(vm.runtime.alloc);
    defer {
        var it = type_annotations.iterator();
        while (it.next()) |entry|
            compiler.types.deinitType(@constCast(entry.value_ptr), vm.runtime.alloc);
        type_annotations.deinit();
    }

    var known_globals = try std.ArrayList([]const u8)
        .initCapacity(vm.runtime.alloc, vm.const_globals.count());
    defer known_globals.deinit(vm.runtime.alloc);
    {
        var cit = vm.const_globals.keyIterator();
        while (cit.next()) |atom_id| {
            try known_globals.append(vm.runtime.alloc, vm.stringValue(atom_id.*));
        }
        var git = vm.globals.iterator();
        while (git.next()) |entry| {
            try known_globals.append(vm.runtime.alloc, vm.stringValue(entry.key_ptr.*));
        }
    }

    const PipelineResolver = struct {
        vm: *VM,
        fn resolve(ptr: *anyopaque, path: []const u8, a: std.mem.Allocator) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (comptime !revo.is_freestanding) {
                const resolved = (resolveModuleFile(self.vm, path) catch return null) orelse return null;
                defer self.vm.runtime.alloc.free(resolved);
                // shared libs carry their sigs as data, instead of source source
                // a sibling `lib.d.rv` manifest is the type interface and required for
                // typed imports; without one the module resolves untyped
                if (std.mem.endsWith(u8, resolved, ".so") or std.mem.endsWith(u8, resolved, ".dylib")) {
                    if (revo.extensionManifestFor(self.vm.runtime.io, a, resolved) catch null) |manifest| {
                        defer a.free(manifest);
                        return std.Io.Dir.cwd().readFileAlloc(self.vm.runtime.io, manifest, a, std.Io.Limit.unlimited) catch null;
                    }
                    return null;
                }
                return std.Io.Dir.cwd().readFileAlloc(self.vm.runtime.io, resolved, a, std.Io.Limit.unlimited) catch null;
            }
            return null;
        }
    };
    var pipeline_resolver = PipelineResolver{ .vm = vm };

    if (try lang.semantic.analyze(
        vm.runtime.alloc,
        expanded.root,
        source.name orelse "",
        source.text,
        known_globals.items,
        null,
        &type_annotations,
        null,
        .{ .ptr = &pipeline_resolver, .resolveFn = PipelineResolver.resolve },
    )) |semantic_err| {
        // the original report is arena-owned inside semantic.analyze; copy it
        // out and take ownership of the source text (deinitError frees it)
        var copied = try semantic_err.semantic.report.copy(vm.runtime.diag_alloc);
        if (source.name) |name| copied.source_name = try vm.runtime.diag_alloc.dupe(u8, name);
        copied.source = try vm.runtime.diag_alloc.dupe(u8, source.text);
        deinitError(vm.runtime.alloc, semantic_err);
        return .{ .err = .{ .semantic = .{ .kind = semantic_err.semantic.kind, .report = copied } } };
    }

    const lower_result = try lower(vm, expanded, .{
        .install_debug_info = opts.install_debug_info,
        .source = source,
        .test_mode = opts.test_mode,
    }, &type_annotations);
    return switch (lower_result) {
        .ok => |artifact| .{ .ok = artifact },
        .err => |failure| .{ .err = .{ .lower = failure } },
    };
}

pub const Source = struct {
    text: []const u8,
    name: ?[]const u8 = null,
};

pub const ParseOptions = struct {
    include_stdlib_macros: bool = false,
};

pub const LowerOptions = struct {
    install_debug_info: bool = false,
    source: ?Source = null,
    test_mode: bool = false,
};
pub const RunMode = enum {
    script,
    project,
};

pub const BuildOptions = struct {
    include_stdlib_macros: bool = true,
    install_debug_info: bool = true,
    test_mode: bool = false,
    mode: RunMode = .script,
    module_scope: bool = false, // build exports table from pub decls
    skip_preload: bool = false, // for repl
};

pub const Parsed = struct {
    root: *Node,
};

pub const Expanded = struct {
    root: *Node,
};

pub const ExpandFailure = struct {
    report: diagnostic.Report,
};

pub const Error = union(enum) {
    parse: parser.ParseFailure,
    expand: ExpandFailure,
    lower: compiler.LowerFailure,
    semantic: compiler.LowerFailure,
};

pub const ParseResult = Result(Parsed, parser.ParseFailure);
pub const ExpandError = expander.ExpandError || proc.ExpandError;
pub const ExpandResult = Result(Expanded, ExpandError);
pub const ExpandWithVmResult = union(enum) {
    ok: Expanded,
    proc_err: diagnostic.Report,
    macro_err: diagnostic.Report,
};

/// a `!` call surviving all expansion passes.
const UnexpandedMacro = struct {
    name: []const u8,
    span: ast.Span,
};

const UnexpandedVisitor = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(UnexpandedMacro),

    pub fn visit(self: *@This(), node: *const Node) void {
        if (node.expr == .call) {
            const callee = node.expr.call.callee;
            switch (callee.expr) {
                .ident => |n| if (std.mem.endsWith(u8, n, "!")) {
                    self.out.append(self.alloc, .{ .name = n, .span = callee.span }) catch return;
                },
                .field => |f| if (std.mem.endsWith(u8, f.name, "!")) {
                    var parts: [16][]const u8 = undefined;
                    var part_count: usize = 0;
                    {
                        var cur: *const Node = f.object;
                        while (true) {
                            switch (cur.expr) {
                                .ident => |n| {
                                    parts[part_count] = n;
                                    part_count += 1;
                                    break;
                                },
                                .field => |fld| {
                                    parts[part_count] = fld.name;
                                    part_count += 1;
                                    cur = fld.object;
                                },
                                else => break,
                            }
                            if (part_count == parts.len) break;
                        }
                    }
                    // reverse parts so they're in base..field order
                    var i: usize = 0;
                    var j: usize = part_count;
                    while (i < j) {
                        j -= 1;
                        const tmp = parts[i];
                        parts[i] = parts[j];
                        parts[j] = tmp;
                        i += 1;
                    }
                    // append f.name as the final field
                    if (part_count < parts.len) {
                        parts[part_count] = f.name;
                        part_count += 1;
                    }
                    const full_name = blk: {
                        var name = self.alloc.dupe(u8, parts[0]) catch return;
                        for (parts[1..part_count]) |part| {
                            const combined = std.fmt.allocPrint(
                                self.alloc,
                                "{s}.{s}",
                                .{ name, part },
                            ) catch {
                                self.alloc.free(name);
                                return;
                            };
                            self.alloc.free(name);
                            name = combined;
                        }
                        break :blk name;
                    };
                    self.out.append(self.alloc, .{ .name = full_name, .span = callee.span }) catch {
                        self.alloc.free(full_name);
                        return;
                    };
                },
                else => {},
            }
        }
        ast.walkAST(UnexpandedVisitor, self, node);
    }
};

/// unknown macros are like pattern misses; both fail at runtime
/// quasiquote pruned by the walk
fn collectUnexpandedMacros(alloc: std.mem.Allocator, root: *const Node) ![]UnexpandedMacro {
    var out = try std.ArrayList(UnexpandedMacro).initCapacity(alloc, 4);
    errdefer out.deinit(alloc);

    var visitor = UnexpandedVisitor{ .alloc = alloc, .out = &out };
    visitor.visit(root);

    return out.toOwnedSlice(alloc);
}

pub const LowerResult = Result(Artifact, compiler.LowerFailure);
pub const BuildResult = Result(Artifact, Error);

pub fn parse(allocator: std.mem.Allocator, source: Source, opts: ParseOptions) !ParseResult {
    if (!opts.include_stdlib_macros) {
        return switch (try parseSourceReport(allocator, source.text)) {
            .ok => |expr| .{ .ok = .{ .root = expr } },
            .err => |failure| blk: {
                var diag = failure;
                if (source.name) |name| diag.report.source_name = name;
                break :blk .{ .err = diag };
            },
        };
    }

    // manifest macros replace the old fixed prelude: same merge shape,
    // authority lives in iface/*.d.rv instead of a lang-side string.
    // the list is permanent like full_specs, never freed.
    const macro_srcs = try revo.std_lib.api.macroSources(allocator);
    var preludes = try std.ArrayList(*Node).initCapacity(allocator, macro_srcs.len);
    defer preludes.deinit(allocator);
    for (macro_srcs) |src| {
        switch (try parseSourceReport(allocator, src)) {
            .ok => |root| try preludes.append(allocator, root),
            .err => |failure| return .{ .err = failure },
        }
    }
    const user: ParseResult = switch (try parseSourceReport(allocator, source.text)) {
        .ok => |root| .{ .ok = .{ .root = root } },
        .err => |failure| blk: {
            var diag = failure;
            if (source.name) |name| diag.report.source_name = name;
            break :blk .{ .err = diag };
        },
    };
    if (user == .err) return .{ .err = user.err };
    return .{ .ok = .{ .root = try mergeWithPreludes(allocator, preludes.items, user.ok.root) } };
}

pub fn expand(allocator: std.mem.Allocator, parsed: Parsed) !ExpandResult {
    const template_expanded = expander.expandExpr(allocator, parsed.root) catch |err| return .{ .err = err };
    const final = expander.expandExpr(allocator, template_expanded) catch |err| return .{ .err = err };
    return .{ .ok = .{ .root = final } };
}

pub fn expandWithVmSource(
    vm: *VM,
    allocator: std.mem.Allocator,
    parsed: Parsed,
    source_name: []const u8,
    source: []const u8,
) !ExpandWithVmResult {
    const template_expanded = try expander.expandExpr(allocator, parsed.root);
    const proc_result = try proc.expandExprWithSource(vm, allocator, template_expanded, source_name, source);

    if (proc_result.error_report) |report|
        return .{ .proc_err = report };

    const final = try expander.expandExpr(allocator, proc_result.root.?);
    const missed = try collectUnexpandedMacros(allocator, final);

    if (missed.len > 0) {
        return .{ .macro_err = try macroReport(allocator, source_name, source, missed) };
    }
    return .{ .ok = .{ .root = final } };
}

/// one unknown-macro error per surviving callsite
fn macroReport(
    allocator: std.mem.Allocator,
    source_name: []const u8,
    source: []const u8,
    missed: []UnexpandedMacro,
) !diagnostic.Report {
    const fmt = "unknown macro `{s}`";
    var parts = try std.ArrayList(diagnostic.Part).initCapacity(allocator, missed.len * 2);
    errdefer parts.deinit(allocator);

    for (missed) |m| {
        const msg = try std.fmt.allocPrint(allocator, fmt, .{m.name});
        try parts.append(allocator, .{ .@"error" = msg });
        try parts.append(allocator, .{ .span = .{ .span = m.span, .role = .primary } });
    }

    const first = try std.fmt.allocPrint(allocator, fmt, .{missed[0].name});
    return .{
        .message = first,
        .parts = try parts.toOwnedSlice(allocator),
        .source_name = source_name,
        .source = source,
    };
}

pub fn lower(
    vm: *VM,
    expanded: Expanded,
    opts: LowerOptions,
    type_annotations: ?*const std.AutoHashMap(*const Node, compiler.types.TypeInfo),
) !LowerResult {
    const lowered = try compiler.lowerExprArtifactReport(
        vm,
        expanded.root,
        opts.test_mode,
        type_annotations,
    );
    return switch (lowered) {
        .ok => |artifact| blk: {
            if (opts.install_debug_info) {
                const source: Source = opts.source orelse Source{ .text = "", .name = "<source>" };
                try vm.setProgramDebugInfo(artifact.spans, source.text, source.name orelse "<source>");
            }
            break :blk .{ .ok = artifact };
        },
        .err => |failure| blk: {
            var diag = failure;
            if (opts.source) |source| {
                if (source.name) |name| diag.report.source_name = name;
            }
            break :blk .{ .err = diag };
        },
    };
}

pub fn renderError(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: Source, err: Error) !void {
    return switch (err) {
        .parse => |failure| blk: {
            var report = failure.report;
            report.source_name = report.source_name orelse source.name;
            report.source = source.text;
            break :blk diagnostic.renderReport(allocator, writer, report);
        },
        .expand => |failure| blk: {
            break :blk diagnostic.renderReport(allocator, writer, failure.report);
        },
        .lower => |failure| blk: {
            var report = failure.report;
            report.source_name = report.source_name orelse source.name;
            report.source = source.text;
            break :blk diagnostic.renderReport(allocator, writer, report);
        },
        .semantic => |failure| blk: {
            var report = failure.report;
            report.source_name = report.source_name orelse source.name;
            report.source = source.text;
            break :blk diagnostic.renderReport(allocator, writer, report);
        },
    };
}

pub fn deinitError(alloc: std.mem.Allocator, err: Error) void {
    var mutable = err;
    switch (mutable) {
        .parse => |*failure| failure.report.deinit(alloc),
        .expand => |*failure| failure.report.deinit(alloc),
        .lower => |*failure| failure.report.deinit(alloc),
        .semantic => |*failure| failure.report.deinit(alloc),
    }
}

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) !*Node {
    return switch (try parseSourceReport(allocator, source)) {
        .ok => |expr| expr,
        .err => |failure| switch (failure.kind) {
            .LexUnexpectedCharacter => error.UnexpectedCharacter,
            .LexUnterminatedComment => error.UnterminatedComment,
            .LexUnterminatedString => error.UnterminatedString,
            .LexLateModuleDoc => error.LateModuleDoc,
            .UnexpectedToken => error.UnexpectedToken,
            .ExpectedIdentifier => error.ExpectedIdentifier,
            .ExpectedMatchArm => error.ExpectedMatchArm,
            .LexUnknown => error.ParseFailed,
            .InvalidNumber => error.ParseFailed,
        },
    };
}

pub fn parseSourceReport(allocator: std.mem.Allocator, source: []const u8) !parser.ParseResult {
    const lexed = try Lexer.lexReportAt(allocator, source, .{});
    const tokens = switch (lexed) {
        .ok => |items| items,
        .err => |failure| {
            const kind: parser.Kind = switch (failure.kind) {
                .UnexpectedCharacter => .LexUnexpectedCharacter,
                .UnterminatedComment => .LexUnterminatedComment,
                .UnterminatedString => .LexUnterminatedString,
                .LateModuleDoc => .LexLateModuleDoc,
                .Unknown => .LexUnknown,
            };
            const parts = try allocator.alloc(diagnostic.Part, 2);
            parts[0] = diagnostic.Part{ .@"error" = failure.message };
            parts[1] = .{ .span = .{ .span = failure.span, .role = .primary } };
            return .{ .err = .{
                .kind = kind,
                .report = .{ .parts = parts, .message = failure.message },
            } };
        },
    };
    defer allocator.free(tokens);
    return parser.parseTokensReport(allocator, tokens);
}

/// flat merge of prelude roots before user code: one shared scope, so
/// later definitions win on redeclaration
fn mergeWithPreludes(allocator: std.mem.Allocator, preludes: []const *Node, user: *Node) !*Node {
    var items = try std.ArrayList(*Node).initCapacity(allocator, 8);
    var span = user.span;
    for (preludes) |pre| {
        span = ast.Span.merge(span, pre.span);
        switch (pre.expr) {
            .block => |block| try items.appendSlice(allocator, block),
            else => try items.append(allocator, pre),
        }
    }
    switch (user.expr) {
        .block => |block| {
            if (user.synthetic_block) {
                try items.appendSlice(allocator, block);
            } else {
                try items.append(allocator, user);
            }
        },
        else => try items.append(allocator, user),
    }
    const node = try allocator.create(Node);
    node.* = .{
        .span = span,
        .expr = .{ .block = try items.toOwnedSlice(allocator) },
    };
    return node;
}

const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;
const Result = revo.Result;

const lang = @import("./root.zig");
const ast = lang.ast;
const Node = ast.Node;
const compiler = lang.compiler;
const expander = lang.expander;
const proc = lang.proc;
const Lexer = lang.Lexer;
const parser = lang.parser;
const diagnostic = lang.diagnostic;
pub const Artifact = compiler.Artifact;
pub const ParseFailure = parser.ParseFailure;
pub const LowerFailure = compiler.LowerFailure;
