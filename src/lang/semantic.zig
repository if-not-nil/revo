const std = @import("std");

const lang = @import("./root.zig");
const ast = @import("./ast.zig");
const diagnostic = @import("diagnostic.zig");
const struct_layout = @import("compiler/struct_layout.zig");
const types_mod = @import("compiler/types.zig");
const revo = @import("revo");

/// run semantic analysis; known_globals are names that exist at runtime (builtins)
/// type_map, if set, is populated with name -> type_name during analysis
pub fn analyze(
    alloc: std.mem.Allocator,
    root: *const ast.Node,
    source_name: []const u8,
    source: []const u8,
    known_globals: []const []const u8,
    type_map: ?*std.StringHashMap([]const u8),
    type_annotations: ?*std.AutoHashMap(*const ast.Node, types_mod.TypeInfo),
) !?lang.Error {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var checker = try SemanticChecker.init(arena_alloc, source_name, source, known_globals, type_map, type_annotations);
    defer checker.deinit();

    _ = try checker.visit(root);
    if (type_map) |tm| try reparentTypeMap(tm, alloc);
    if (checker.errors.items.len == 0) return null;

    const report = try checker.finishReport();
    const copied = try report.copy(alloc);
    return .{ .semantic = .{ .kind = .ParseError, .report = copied } };
}

fn reparentTypeMap(tm: *std.StringHashMap([]const u8), alloc: std.mem.Allocator) !void {
    var keys = try std.ArrayList([]const u8).initCapacity(alloc, tm.count());
    defer keys.deinit(alloc);
    var vals = try std.ArrayList([]const u8).initCapacity(alloc, tm.count());
    defer vals.deinit(alloc);
    var it = tm.iterator();
    while (it.next()) |entry| {
        keys.appendAssumeCapacity(try alloc.dupe(u8, entry.key_ptr.*));
        vals.appendAssumeCapacity(try alloc.dupe(u8, entry.value_ptr.*));
    }
    tm.clearRetainingCapacity();
    for (keys.items, vals.items) |k, v|
        try tm.put(k, v);
}

const Scope = struct {
    values: std.StringHashMap(types_mod.TypeInfo),

    fn init(alloc: std.mem.Allocator) Scope {
        return .{ .values = std.StringHashMap(types_mod.TypeInfo).init(alloc) };
    }

    fn deinit(self: *Scope) void {
        self.values.deinit();
    }
};

const FnSig = struct {
    param_names: []const []const u8,
    param_types: []const types_mod.TypeInfo,
    return_type: types_mod.TypeInfo,
    sig: types_mod.FunctionSignature,
    required_count: usize,
};

const SemanticChecker = struct {
    alloc: std.mem.Allocator,
    source_name: []const u8,
    source: []const u8,
    errors: std.ArrayList(diagnostic.Part),
    scopes: std.ArrayList(Scope),
    type_aliases: std.StringHashMap(types_mod.TypeInfo),
    struct_layouts: std.StringHashMap([]const struct_layout.FieldDef),
    fn_sigs: std.ArrayList(*FnSig),
    return_types: std.ArrayList(types_mod.TypeInfo),
    type_map: ?*std.StringHashMap([]const u8),
    type_annotations: ?*std.AutoHashMap(*const ast.Node, types_mod.TypeInfo),
    typed_names: std.StringHashMap(void),
    table_field_map: std.StringHashMap(std.StringHashMap(types_mod.TypeInfo)),

    fn init(
        alloc: std.mem.Allocator,
        source_name: []const u8,
        source: []const u8,
        known_globals: []const []const u8,
        type_map: ?*std.StringHashMap([]const u8),
        type_annotations: ?*std.AutoHashMap(*const ast.Node, types_mod.TypeInfo),
    ) !SemanticChecker {
        var checker: SemanticChecker = .{
            .alloc = alloc,
            .source_name = source_name,
            .source = source,
            .errors = undefined,
            .scopes = undefined,
            .type_aliases = std.StringHashMap(types_mod.TypeInfo).init(alloc),
            .struct_layouts = std.StringHashMap([]const struct_layout.FieldDef).init(alloc),
            .fn_sigs = undefined,
            .return_types = undefined,
            .type_map = type_map,
            .type_annotations = type_annotations,
            .typed_names = std.StringHashMap(void).init(alloc),
            .table_field_map = std.StringHashMap(std.StringHashMap(types_mod.TypeInfo)).init(alloc),
        };
        checker.errors = try std.ArrayList(diagnostic.Part).initCapacity(alloc, 8);
        errdefer checker.errors.deinit(alloc);
        checker.scopes = try std.ArrayList(Scope).initCapacity(alloc, 4);
        errdefer checker.scopes.deinit(alloc);
        checker.fn_sigs = try std.ArrayList(*FnSig).initCapacity(alloc, 4);
        errdefer checker.fn_sigs.deinit(alloc);
        checker.return_types = try std.ArrayList(types_mod.TypeInfo).initCapacity(alloc, 4);
        errdefer checker.return_types.deinit(alloc);
        
        try checker.pushScope();
        // registers builtins
        for (known_globals) |name|
            try checker.declare(name, .any);

        // registers stdlib function types
        // prefer specs with global placement for global names
        for (known_globals) |name| {
            const spec = find_global: {
                for (revo.std_lib.api.all_specs) |group| for (group) |s| {
                    if (!std.mem.eql(u8, s.name, name)) continue;
                    for (s.placements) |pl| if (pl.kind == .global) break :find_global s;
                };
                break :find_global revo.std_lib.api.find(name);
            } orelse continue;
            if (try checker.makeStdlibSig(spec)) |sig| {
                try checker.scopes.items[checker.scopes.items.len - 1].values.put(name, .{ .function = &sig.sig });
            }
        }
        return checker;
    }

    fn deinit(self: *SemanticChecker) void {
        for (self.scopes.items) |*scope| scope.deinit();
        self.scopes.deinit(self.alloc);
    }

    fn finishReport(self: *SemanticChecker) !diagnostic.Report {
        const parts = try self.errors.toOwnedSlice(self.alloc);
        const first_msg = for (parts) |p| {
            if (p == .@"error") break p.@"error";
        } else "";

        return .{
            .parts = parts,
            .message = if (first_msg.len > 0) try self.alloc.dupe(u8, first_msg) else "",
            .source_name = try self.alloc.dupe(u8, self.source_name),
            .source = try self.alloc.dupe(u8, self.source),
        };
    }

    fn pushScope(self: *SemanticChecker) !void {
        try self.scopes.append(self.alloc, Scope.init(self.alloc));
    }

    fn popScope(self: *SemanticChecker) void {
        _ = self.scopes.pop();
    }

    fn declare(self: *SemanticChecker, name: []const u8, t: types_mod.TypeInfo) !void {
        if (self.scopes.items.len == 0) try self.pushScope();
        try self.scopes.items[self.scopes.items.len - 1].values.put(name, t);

        if (self.type_map) |tm| {
            if (!tm.contains(name)) {
                const ts = types_mod.typeName(t);
                try tm.put(
                    try self.alloc.dupe(u8, name),
                    try self.alloc.dupe(u8, ts),
                );
            }
        }
    }

    fn lookup(self: *SemanticChecker, name: []const u8) ?types_mod.TypeInfo {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].values.get(name)) |v| return v;
        }
        return self.type_aliases.get(name);
    }

    // ctx interface for types.zig
    pub fn inferIdentType(self: *SemanticChecker, name: []const u8) types_mod.TypeInfo {
        return self.lookup(name) orelse .any;
    }

    pub fn inferFnType(self: *SemanticChecker, params: []const ast.FnParam, return_type: ?*ast.TypeExpr) types_mod.TypeInfo {
        const sig = self.makeFnSig(.{ .params = params, .return_type = return_type }) catch return .any;
        return .{ .function = &sig.sig };
    }

    pub fn resolveTypeAlias(self: *SemanticChecker, name: []const u8) ?types_mod.TypeInfo {
        return self.type_aliases.get(name);
    }

    pub fn inferCallReturnType(self: *SemanticChecker, callee: *const ast.Node, args: []const *ast.Node) types_mod.TypeInfo {
        _ = args;
        const callee_type = types_mod.inferExprType(self, callee);
        if (callee_type == .function) return callee_type.function.return_type;
        return .any;
    }

    pub fn inferFieldType(self: *SemanticChecker, object: *const ast.Node, name: []const u8) types_mod.TypeInfo {
        const object_type = types_mod.inferExprType(self, object);
        // user-defined table fields shadow stdlib methods
        if (object_type == .struct_type and std.mem.eql(u8, object_type.struct_type, "table") and object.expr == .ident) {
            if (self.table_field_map.get(object.expr.ident)) |fields| {
                if (fields.get(name)) |ft| return ft;
            }
        }
        // method lookup for string, tuple, and table
        const target: ?revo.std_lib.TypeSpec = switch (object_type) {
            .string => .string,
            .tuple => .tuple,
            .struct_type => |n| if (std.mem.eql(u8, n, "table")) .table else null,
            else => null,
        };
        if (target) |t| {
            if (findMethodByNameAndTarget(name, t)) |spec| {
                if (self.makeStdlibSig(spec) catch null) |sig| {
                    return .{ .function = &sig.sig };
                }
            }
        }
        // struct field access
        if (object_type == .struct_type) {
            const struct_name = object_type.struct_type;
            const layout = self.struct_layouts.get(struct_name) orelse return .any;
            for (layout) |f| if (std.mem.eql(u8, f.name, name)) return if (f.field_type != .any) f.field_type else if (f.type_name) |tn| types_mod.resolveTypeName(self, tn) else .any;
        }
        return .any;
    }

    fn makeStdlibSig(self: *SemanticChecker, spec: revo.std_lib.api.FnSpec) !?*FnSig {
        var param_types = try std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, spec.params.len);
        var param_names = try std.ArrayList([]const u8).initCapacity(self.alloc, spec.params.len);
        for (spec.params) |p| {
            try param_names.append(self.alloc, p[0]);
            const resolved = types_mod.resolveTypeName(self, p[1]);
            try param_types.append(self.alloc, switch (resolved) {
                .struct_type, .function => types_mod.TypeInfo.any,
                else => resolved,
            });
        }
        const names_slice = try param_names.toOwnedSlice(self.alloc);
        const types_slice = try param_types.toOwnedSlice(self.alloc);
        const resolved_ret = types_mod.resolveTypeName(self, spec.ret);
        const ret: types_mod.TypeInfo = switch (resolved_ret) {
            .struct_type, .function => .any,
            else => resolved_ret,
        };
        const sig_ptr = try self.alloc.create(FnSig);
        sig_ptr.* = .{
            .param_names = names_slice,
            .param_types = types_slice,
            .return_type = ret,
            .required_count = types_slice.len,
            .sig = .{
                .param_names = names_slice,
                .params = types_slice,
                .return_type = ret,
                .required_count = types_slice.len,
            },
        };
        try self.fn_sigs.append(self.alloc, sig_ptr);
        return sig_ptr;
    }

    fn makeFnSig(self: *SemanticChecker, fn_expr: anytype) !*FnSig {
        var param_names = try std.ArrayList([]const u8).initCapacity(self.alloc, fn_expr.params.len);
        var param_types = try std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, fn_expr.params.len);
        var required_count: usize = 0;
        for (fn_expr.params) |p| {
            try param_names.append(self.alloc, p.name);
            try param_types.append(self.alloc, if (p.type_name) |tn| try types_mod.evalTypeExpr(self, tn) else .any);
            if (!p.optional) required_count += 1;
        }
        const params_slice = try param_types.toOwnedSlice(self.alloc);
        const names_slice = try param_names.toOwnedSlice(self.alloc);
        const ret = if (fn_expr.return_type) |rt| try types_mod.evalTypeExpr(self, rt) else .any;
        const sig_ptr = try self.alloc.create(FnSig);
        sig_ptr.* = .{
            .param_names = names_slice,
            .param_types = params_slice,
            .return_type = ret,
            .required_count = required_count,
            .sig = .{
                .param_names = names_slice,
                .params = params_slice,
                .return_type = ret,
                .required_count = required_count,
            },
        };
        try self.fn_sigs.append(self.alloc, sig_ptr);
        return sig_ptr;
    }

    fn analyzeFnBody(self: *SemanticChecker, fn_expr: anytype, sig: *FnSig) !types_mod.TypeInfo {
        try self.return_types.append(self.alloc, sig.return_type);
        defer _ = self.return_types.pop();

        try self.pushScope();
        defer self.popScope();
        for (fn_expr.params, sig.param_types) |param, param_type| {
            try self.declare(param.name, param_type);
        }
        const body_type = try self.analyzeNode(fn_expr.body);
        if (sig.return_type == .any and body_type != .any) {
            sig.return_type = body_type;
            sig.sig.return_type = body_type;
        }
        // validate explicit return type against inferred body type
        if (sig.return_type != .any and body_type != .any and !types_mod.canCoerce(body_type, sig.return_type)) {
            try self.appendReturnMismatch(fn_expr.body.span, sig.return_type, body_type);
        }
        return .{ .function = &sig.sig };
    }

    fn analyzeNode(self: *SemanticChecker, node: *const ast.Node) anyerror!types_mod.TypeInfo {
        return switch (node.expr) {
            .binding => |b| try self.analyzeBinding(b, node.span),
            .decl => |d| try self.analyzeDecl(d, node.span),
            .struct_def => |def| try self.analyzeStruct(def, node.span),
            .type_alias => |alias| try self.analyzeTypeAlias(alias, node.span),
            .fn_expr => |fn_expr| try self.analyzeFnExpr(fn_expr, node.span),
            .block => |exprs| try self.analyzeBlock(exprs, node.span),
            .assign_expr => |assign| try self.analyzeAssign(assign, node.span),
            .return_expr => |val| try self.analyzeReturn(val, node.span),
            .call => |call| try self.analyzeCall(call, node.span),
            .if_expr => |v| try self.analyzeIf(v, node.span),
            .ident => |name| try self.analyzeIdent(name, node.span),
            .unary => |u| blk: {
                _ = try self.analyzeNode(u.expr);
                break :blk types_mod.inferExprType(self, node);
            },
            .binary => |b| blk: {
                _ = try self.analyzeNode(b.left);
                _ = try self.analyzeNode(b.right);
                break :blk types_mod.inferExprType(self, node);
            },
            .and_expr => |v| blk: {
                _ = try self.analyzeNode(v.left);
                _ = try self.analyzeNode(v.right);
                break :blk types_mod.inferExprType(self, node);
            },
            .or_expr => |v| blk: {
                _ = try self.analyzeNode(v.left);
                _ = try self.analyzeNode(v.right);
                break :blk types_mod.inferExprType(self, node);
            },
            .try_expr => |inner| blk: {
                const inner_type = try self.analyzeNode(inner);
                if (inner_type != .any) {
                    const is_result = if (inner_type == .tuple and inner_type.tuple.len >= 1) chk: {
                        const first = inner_type.tuple[0];
                        break :chk first == .atom and
                            // handle both with-colon and without-colon conventions
                            (std.mem.eql(u8, first.atom, ":ok") or std.mem.eql(u8, first.atom, "ok") or
                                std.mem.eql(u8, first.atom, ":err") or std.mem.eql(u8, first.atom, "err"));
                    } else false;
                    if (!is_result) {
                        try self.appendError(
                            try std.fmt.allocPrint(self.alloc, "try expects :ok/:err tagged tuple, got {s}", .{types_mod.typeName(inner_type)}),
                            inner.span,
                            "not a result type",
                        );
                    }
                }
                break :blk types_mod.inferExprType(self, node);
            },
            .orelse_expr => |v| blk: {
                _ = try self.analyzeNode(v.left);
                _ = try self.analyzeNode(v.right);
                break :blk types_mod.inferExprType(self, node);
            },
            .field => |f| blk: {
                _ = try self.analyzeNode(f.object);
                break :blk types_mod.inferExprType(self, node);
            },
            .index => |idx| blk: {
                _ = try self.analyzeNode(idx.object);
                _ = try self.analyzeNode(idx.key);
                break :blk types_mod.inferExprType(self, node);
            },
            .range_literal => |v| blk: {
                _ = try self.analyzeNode(v.start);
                _ = try self.analyzeNode(v.end);
                break :blk types_mod.inferExprType(self, node);
            },
            .comp_block => |v| blk: {
                _ = try self.analyzeNode(v.expr);
                break :blk types_mod.inferExprType(self, node);
            },
            .import_expr => |path| blk: {
                _ = try self.analyzeNode(path);
                break :blk types_mod.inferExprType(self, node);
            },
            .break_expr => |val| blk: {
                if (val) |v| _ = try self.analyzeNode(v);
                break :blk types_mod.inferExprType(self, node);
            },
            .for_loop => |v| blk: {
                const iter_type = try self.analyzeNode(v.iter);
                try self.pushScope();
                const param_type: types_mod.TypeInfo = if (v.iter.expr == .range_literal)
                    .int
                else if (iter_type == .string)
                    .string
                else
                    .any;
                for (v.params) |param| {
                    try self.declare(param.name, param_type);
                }
                const body_type = try self.analyzeNode(v.body);
                self.popScope();
                break :blk body_type;
            },
            .match_expr => |v| blk: {
                _ = try self.analyzeNode(v.subject);
                var unified: types_mod.TypeInfo = .any;
                for (v.arms) |arm| {
                    try self.pushScope();
                    for (arm.matchers) |matcher| {
                        if (matcher == .expr) {
                            _ = try self.declarePatternNames(matcher.expr);
                        }
                    }
                    if (arm.guard) |g| _ = try self.analyzeNode(g);
                    const arm_type = try self.analyzeNode(arm.then);
                    self.popScope();
                    unified = if (unified == .any) arm_type else if (arm_type == .any) unified else if (unified.eql(arm_type)) unified else .any;
                }
                break :blk unified;
            },
            .loop_expr => |v| blk: {
                try self.pushScope();
                _ = try self.analyzeNode(v.body);
                self.popScope();
                break :blk types_mod.inferExprType(self, node);
            },
            .while_loop => |v| blk: {
                const pred_type = try self.analyzeNode(v.predicate);
                if (!types_mod.canCoerce(pred_type, .bool)) {
                    try self.appendError(
                        try std.fmt.allocPrint(self.alloc, "while predicate must be boolean, got {s}", .{types_mod.typeName(pred_type)}),
                        v.predicate.span,
                        "expected bool",
                    );
                }
                try self.pushScope();
                _ = try self.analyzeNode(v.body);
                self.popScope();
                break :blk types_mod.inferExprType(self, node);
            },
            .number, .string, .multiline_string, .hash, .nil, .tuple, .table, .tuple_pattern, .macro_expr, .test_block, .test_suite, .proc_macro => types_mod.inferExprType(self, node),
        };
    }

    fn analyzeIdent(self: *SemanticChecker, name: []const u8, span: ast.Span) !types_mod.TypeInfo {
        if (self.lookup(name) == null and !ast.isDiscardName(name)) {
            const msg = try std.fmt.allocPrint(self.alloc, "name `{s}` is not defined", .{name});
            try self.appendError(msg, span, "unknown name");
        }
        return self.inferIdentType(name);
    }

    fn visit(self: *SemanticChecker, node: *const ast.Node) !types_mod.TypeInfo {
        const t = try self.analyzeNode(node);
        if (self.type_annotations) |map| {
            map.put(node, t) catch {};
        }
        return t;
    }

    fn analyzeBlock(self: *SemanticChecker, exprs: []const *ast.Node, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        try self.pushScope();
        defer self.popScope();
        var last: types_mod.TypeInfo = .any;
        for (exprs) |expr| {
            last = try self.analyzeNode(expr);
        }
        return last;
    }

    fn analyzeDecl(self: *SemanticChecker, decl: ast.DeclNode, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        return switch (decl.inner.expr) {
            .binding => |b| try self.analyzeBinding(b, decl.inner.span),
            .type_alias => |alias| try self.analyzeTypeAlias(alias, decl.inner.span),
            .struct_def => |def| try self.analyzeStruct(def, decl.inner.span),
            else => try self.analyzeNode(decl.inner),
        };
    }

    fn analyzeTypeAlias(self: *SemanticChecker, alias: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        const t = types_mod.evalTypeExpr(self, alias.type_expr) catch .any;
        try self.type_aliases.put(alias.name, t);
        return .any;
    }

    fn analyzeStruct(self: *SemanticChecker, def: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        var seen = std.StringHashMap(void).init(self.alloc);
        var fields = try std.ArrayList(struct_layout.FieldDef).initCapacity(self.alloc, def.items.len);

        for (def.items) |item| switch (item) {
            .field => |field| {
                if (seen.contains(field.name)) {
                    try self.appendError(
                        try std.fmt.allocPrint(self.alloc, "duplicate field `{s}` in struct `{s}`", .{ field.name, def.name }),
                        field.name_span,
                        "duplicate field",
                    );
                    continue;
                }
                try seen.put(field.name, {});
                const field_type: types_mod.TypeInfo = if (field.type_name) |tn|
                    try types_mod.evalTypeExpr(self, tn)
                else if (field.default_value) |dflt|
                    types_mod.inferExprType(self, dflt)
                else
                    .any;
                try fields.append(self.alloc, .{
                    .name = field.name,
                    .type_name = if (field.type_name) |tn| switch (tn.kind) {
                        .named => |n| n,
                        else => types_mod.typeName(field_type),
                    } else null,
                    .field_type = field_type,
                });
            },
            .binding => |b| {
                _ = try self.analyzeBinding(b, b.target.span);
            },
        };

        const slice = try fields.toOwnedSlice(self.alloc);
        try self.struct_layouts.put(def.name, slice);
        try self.declare(def.name, .{ .struct_type = def.name });
        return .{ .struct_type = def.name };
    }

    fn analyzeFnExpr(self: *SemanticChecker, fn_expr: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        const sig = try self.makeFnSig(fn_expr);
        return self.analyzeFnBody(fn_expr, sig);
    }

    fn analyzeBinding(self: *SemanticChecker, binding: ast.Binding, _: ast.Span) !types_mod.TypeInfo {
        if (binding.target.expr != .ident) {
            if (binding.target.expr == .tuple_pattern) {
                _ = try self.analyzeNode(binding.value);
                return self.declarePatternNames(binding.target);
            }
            return .any;
        }
        const name = binding.target.expr.ident;
        if (binding.value.expr == .fn_expr) {
            const sig = try self.makeFnSig(binding.value.expr.fn_expr);
            const fn_type: types_mod.TypeInfo = .{ .function = &sig.sig };
            if (binding.type_name) |type_expr| {
                try self.typed_names.put(name, {});
                const expected = try types_mod.evalTypeExpr(self, type_expr);
                if (!types_mod.canCoerce(fn_type, expected)) {
                    const name_str = try types_mod.formatType(self.alloc, expected);
                    try self.appendTypeMismatch(
                        binding.target.span,
                        name,
                        name_str,
                        fn_type,
                    );
                }
                try self.declare(name, expected);
            } else {
                try self.declare(name, fn_type);
            }
            _ = try self.analyzeFnBody(binding.value.expr.fn_expr, sig);
            return fn_type;
        }

        // table literal -- analyze entries and record field types for method shadowing
        if (binding.value.expr == .table) {
            var fields = std.StringHashMap(types_mod.TypeInfo).init(self.alloc);
            for (binding.value.expr.table) |entry| {
                if (entry.key) |key| {
                    if (key.expr == .ident) {
                        const field_type = try self.analyzeNode(entry.value);
                        try fields.put(key.expr.ident, field_type);
                    } else {
                        _ = try self.analyzeNode(entry.value);
                    }
                } else {
                    _ = try self.analyzeNode(entry.value);
                }
            }
            try self.table_field_map.put(name, fields);
            if (binding.type_name) |type_expr| {
                try self.typed_names.put(name, {});
                const expected = try types_mod.evalTypeExpr(self, type_expr);
                if (!types_mod.canCoerce(.{ .struct_type = "table" }, expected)) {
                    const name_str = try types_mod.formatType(self.alloc, expected);
                    try self.appendTypeMismatch(
                        binding.target.span,
                        name,
                        name_str,
                        .{ .struct_type = "table" },
                    );
                }
                try self.declare(name, expected);
                return expected;
            }
            try self.declare(name, .{ .struct_type = "table" });
            return .{ .struct_type = "table" };
        }
        // propagate table fields through variable references
        if (binding.value.expr == .ident and !ast.isDiscardName(binding.value.expr.ident)) {
            if (self.table_field_map.get(binding.value.expr.ident)) |src| {
                const fields = try src.clone();
                try self.table_field_map.put(name, fields);
            }
        }

        const value_type = try self.analyzeNode(binding.value);
        if (binding.type_name) |type_expr| {
            try self.typed_names.put(name, {});
            const expected = try types_mod.evalTypeExpr(self, type_expr);
            if (!types_mod.canCoerce(value_type, expected)) {
                const name_str = try types_mod.formatType(self.alloc, expected);
                try self.appendTypeMismatch(
                    binding.target.span,
                    name,
                    name_str,
                    value_type,
                );
            }
            try self.declare(name, expected);
            return expected;
        }

        try self.declare(name, value_type);
        return value_type;
    }

    fn declarePatternNames(self: *SemanticChecker, pattern: *const ast.Node) !types_mod.TypeInfo {
        switch (pattern.expr) {
            .ident => |name| {
                if (!ast.isDiscardName(name))
                    try self.declare(name, .any);
            },
            .tuple_pattern => |items| {
                for (items) |item| {
                    _ = try self.declarePatternNames(item);
                }
            },
            else => {},
        }
        return .any;
    }

    fn analyzeAssign(self: *SemanticChecker, assign: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        const value_type = try self.analyzeNode(assign.value);
        switch (assign.target.expr) {
            .ident => |name| {
                if (self.typed_names.contains(name)) {
                    if (self.lookup(name)) |expected| {
                        if (!types_mod.canCoerce(value_type, expected)) {
                            try self.appendTypeMismatch(
                                assign.value.span,
                                name,
                                types_mod.typeName(expected),
                                value_type,
                            );
                        }
                    }
                }
                try self.declare(name, value_type);
            },
            .field => |field| {
                const object_type = types_mod.inferExprType(self, field.object);
                if (object_type == .struct_type and std.mem.eql(u8, object_type.struct_type, "table") and field.object.expr == .ident) {
                    if (self.table_field_map.getPtr(field.object.expr.ident)) |fields| {
                        try fields.put(field.name, value_type);
                    }
                }
                if (object_type == .struct_type) {
                    const layout = self.struct_layouts.get(object_type.struct_type) orelse return .any;
                    for (layout) |f| {
                        if (!std.mem.eql(u8, f.name, field.name)) continue;
                        if (!types_mod.canCoerce(value_type, f.field_type)) {
                            try self.appendFieldMismatch(field, f.field_type, value_type);
                        }
                        return .any;
                    }
                }
            },
            .index => |idx| {
                if (idx.key.expr == .hash and idx.object.expr == .ident) {
                    if (self.table_field_map.getPtr(idx.object.expr.ident)) |fields| {
                        try fields.put(idx.key.expr.hash, value_type);
                    }
                }

                const actual_type = try self.analyzeNode(idx.object);
                if (!types_mod.canCoerce(.{ .struct_type = "table" }, actual_type)) {
                    const name_str = try types_mod.formatType(self.alloc, actual_type);

                    try self.appendError(
                        try std.fmt.allocPrint(self.alloc, "mutation is not allowed for {s}", .{name_str}),
                        idx.object.span,
                        "here",
                    );
                }
            },
            else => {
                const target_kind = @tagName(assign.target.expr);
                try self.appendError(
                    try std.fmt.allocPrint(self.alloc, "cannot assign to {s}", .{target_kind}),
                    assign.target.span,
                    "invalid assignment target",
                );
            },
        }
        return .any;
    }

    fn analyzeReturn(self: *SemanticChecker, val: ?*ast.Node, span: ast.Span) !types_mod.TypeInfo {
        const expr = val orelse return .any;
        const actual = try self.analyzeNode(expr);
        const expected = if (self.return_types.items.len != 0) self.return_types.items[self.return_types.items.len - 1] else .any;
        if (expected != .any and !types_mod.canCoerce(actual, expected)) {
            try self.appendReturnMismatch(span, expected, actual);
        }
        return .any;
    }

    fn analyzeCall(self: *SemanticChecker, call: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        const callee_type = types_mod.inferExprType(self, call.callee);
        // struct init validation
        if (callee_type == .struct_type) {
            const struct_name = callee_type.struct_type;
            const layout = self.struct_layouts.get(struct_name) orelse {
                for (call.args) |arg| _ = try self.analyzeNode(arg);
                return .any;
            };
            if (call.args.len > 0 and call.args[0].expr == .table) {
                const table_entries = call.args[0].expr.table;
                for (table_entries) |entry| {
                    const key = entry.key orelse continue;
                    if (key.expr != .ident) continue;
                    for (layout) |fd| {
                        if (!std.mem.eql(u8, fd.name, key.expr.ident)) continue;
                        if (fd.field_type == .any) break;
                        const actual = types_mod.inferExprType(self, entry.value);
                        if (!types_mod.canCoerce(actual, fd.field_type)) {
                            const actual_str = try types_mod.formatType(self.alloc, actual);
                            const expected_str = try types_mod.formatType(self.alloc, fd.field_type);
                            try self.appendError(
                                try std.fmt.allocPrint(self.alloc, "field `{s}` on `{s}` wants {s}, got {s}", .{
                                    fd.name, struct_name, expected_str, actual_str,
                                }),
                                entry.value.span,
                                "wrong type",
                            );
                        }
                        break;
                    }
                }
            }
            for (call.args) |arg| _ = try self.analyzeNode(arg);
            return .any;
        }
        // typed function call validation
        if (callee_type == .function) {
            const sig_ptr = callee_type.function;
            if (sig_ptr.is_any_fn_sig) {
                for (call.args) |arg| _ = try self.analyzeNode(arg);
                return .any;
            }
            const sig = sig_ptr.*;
            const name = switch (call.callee.expr) {
                .ident => |n| n,
                .field => |f| f.name,
                else => "call",
            };
            // method calls (implicit_self) prepend the object as arg 0 at runtime
            const self_offset: usize = if (call.implicit_self) 1 else 0;
            const total_args = call.args.len + self_offset;
            if (total_args < sig.required_count or (total_args > sig.params.len)) {
                const stdlib_spec = revo.std_lib.api.find(name);
                const is_variadic = stdlib_spec != null and stdlib_spec.?.variadic;
                if (is_variadic and total_args >= sig.params.len -| 1) {
                    // variadic fns are fine with >= min
                } else if (total_args < sig.required_count) {
                    const label = try std.fmt.allocPrint(self.alloc, "{d} missing args", .{
                        sig.required_count -| total_args,
                    });
                    try self.appendError(
                        try std.fmt.allocPrint(self.alloc, "`{s}` wants at least {d} args, got {d}", .{
                            name, sig.required_count, total_args,
                        }),
                        call.callee.span,
                        label,
                    );
                } else if (total_args > sig.params.len) {
                    const label = try std.fmt.allocPrint(self.alloc, "{d} extra args", .{
                        total_args -| sig.params.len,
                    });
                    try self.appendError(
                        try std.fmt.allocPrint(self.alloc, "`{s}` wants {d} args, got {d}", .{
                            name, sig.params.len, total_args,
                        }),
                        call.callee.span,
                        label,
                    );
                }
            }
            // handle named arguments
            const has_named = for (call.args) |arg| {
                if (isNamedParam(arg) != null) break true;
            } else false;
            var named_seen = false;
            for (call.args, 0..) |arg, ai| {
                if (isNamedParam(arg) != null) {
                    named_seen = true;
                } else if (named_seen) {
                    try self.appendError(
                        try std.fmt.allocPrint(self.alloc, "positional arg cannot follow named arg", .{}),
                        arg.span,
                        "here",
                    );
                }
                _ = ai;
            }
            for (call.args, 0..) |arg, i| {
                if (isNamedParam(arg)) |pn| {
                    for (call.args[i + 1 ..]) |later_arg| {
                        if (isNamedParam(later_arg)) |later_pn| {
                            if (std.mem.eql(u8, pn, later_pn)) {
                                try self.appendError(
                                    try std.fmt.allocPrint(self.alloc, "duplicate named arg `{s}`", .{pn}),
                                    later_arg.span,
                                    "already specified",
                                );
                            }
                        }
                    }
                }
            }
            if (has_named) {
                for (0..sig.params.len) |i| {
                    if (call.implicit_self and i == 0) {
                        const actual = types_mod.inferExprType(self, call.callee.expr.field.object);
                        const expected = sig.params[i];
                        if (!types_mod.canCoerce(actual, expected)) {
                            try self.appendError(
                                try std.fmt.allocPrint(self.alloc, "arg 1 to `{s}` wants {s}, got {s}", .{
                                    name, types_mod.typeName(expected), types_mod.typeName(actual),
                                }),
                                call.callee.expr.field.object.span,
                                try std.fmt.allocPrint(self.alloc, "not {s} (got {s})", .{
                                    types_mod.typeName(expected), types_mod.typeName(actual),
                                }),
                            );
                        }
                        continue;
                    }
                    const pi = i - self_offset;
                    const expected = sig.params[i];
                    var found = false;
                    for (call.args) |arg| {
                        if (isNamedParam(arg)) |pn| {
                            if (pi < sig.param_names.len and std.mem.eql(u8, sig.param_names[pi], pn)) {
                                _ = try self.analyzeNode(arg.expr.assign_expr.value);
                                const actual = types_mod.inferExprType(self, arg.expr.assign_expr.value);
                                if (!types_mod.canCoerce(actual, expected)) {
                                    try self.appendError(
                                        try std.fmt.allocPrint(self.alloc, "arg `{s}` to `{s}` wants {s}, got {s}", .{
                                            pn, name, types_mod.typeName(expected), types_mod.typeName(actual),
                                        }),
                                        arg.span,
                                        try std.fmt.allocPrint(self.alloc, "not {s} (got {s})", .{
                                            types_mod.typeName(expected), types_mod.typeName(actual),
                                        }),
                                    );
                                }
                                found = true;
                                break;
                            }
                        }
                    }
                    if (!found and pi < call.args.len) {
                        _ = try self.analyzeNode(call.args[pi]);
                        const actual = types_mod.inferExprType(self, call.args[pi]);
                        if (!types_mod.canCoerce(actual, expected)) {
                            const param_name = if (pi < sig.param_names.len and sig.param_names[pi].len > 0) sig.param_names[pi] else "";
                            try self.appendError(
                                try std.fmt.allocPrint(self.alloc, "arg {d} (`{s}`) to `{s}` wants {s}, got {s}", .{
                                    pi + 1, param_name, name, types_mod.typeName(expected), types_mod.typeName(actual),
                                }),
                                call.args[pi].span,
                                try std.fmt.allocPrint(self.alloc, "not {s} (got {s})", .{
                                    types_mod.typeName(expected), types_mod.typeName(actual),
                                }),
                            );
                        }
                    }
                }
                return sig.return_type;
            }
            const count = if (total_args < sig.params.len) total_args else sig.params.len;
            for (0..count) |i| {
                const expected = sig.params[i];
                const actual = if (call.implicit_self and i == 0)
                    types_mod.inferExprType(self, call.callee.expr.field.object)
                else
                    try self.analyzeNode(call.args[i - self_offset]);
                if (!types_mod.canCoerce(actual, expected)) {
                    const param_name = if (i < sig.param_names.len and sig.param_names[i].len > 0) sig.param_names[i] else "";
                    const msg = if (call.implicit_self and i == 0)
                        try std.fmt.allocPrint(self.alloc, "arg 1 (`{s}`) to `{s}` wants {s}, got {s}", .{
                            param_name, name, types_mod.typeName(expected), types_mod.typeName(actual),
                        })
                    else
                        try std.fmt.allocPrint(self.alloc, "arg {d} (`{s}`) to `{s}` wants {s}, got {s}", .{
                            i + 1, param_name, name, types_mod.typeName(expected), types_mod.typeName(actual),
                        });
                    try self.appendError(
                        msg,
                        if (call.implicit_self and i == 0) call.callee.expr.field.object.span else call.args[i - self_offset].span,
                        try std.fmt.allocPrint(self.alloc, "not {s} (got {s})", .{
                            types_mod.typeName(expected),
                            types_mod.typeName(actual),
                        }),
                    );
                }
            }
            return sig.return_type;
        }

        for (call.args) |arg| _ = try self.analyzeNode(arg);
        return .any;
    }

    fn isNamedParam(arg: *const ast.Node) ?[]const u8 {
        if (arg.expr != .assign_expr) return null;
        const assign = arg.expr.assign_expr;
        if (assign.target.expr != .ident) return null;
        return assign.target.expr.ident;
    }

    fn findMethodByNameAndTarget(name: []const u8, target: revo.std_lib.TypeSpec) ?revo.std_lib.api.FnSpec {
        for (revo.std_lib.api.all_specs) |group| {
            for (group) |spec| {
                if (!std.mem.eql(u8, spec.name, name)) continue;
                for (spec.placements) |pl| {
                    if (pl.kind == .method)
                        if (pl.target) |t| if (std.meta.activeTag(t) == std.meta.activeTag(target)) return spec;
                }
            }
        }
        return null;
    }

    fn analyzeIf(self: *SemanticChecker, v: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        _ = try self.analyzeNode(v.condition);
        const then_type = try self.analyzeNode(v.then_expr);
        if (v.else_expr) |else_expr| {
            const else_type = try self.analyzeNode(else_expr);

            return if (then_type == .any) else_type else then_type;
        }
        return .any;
    }

    fn appendTypeMismatch(
        self: *SemanticChecker,
        span: ast.Span,
        name: []const u8,
        expected_name: []const u8,
        actual: types_mod.TypeInfo,
    ) !void {
        const actual_str = try types_mod.formatType(self.alloc, actual);
        const msg = try std.fmt.allocPrint(self.alloc, "`{s}` wants {s}, got {s}", .{
            name,
            expected_name,
            actual_str,
        });
        const label = try std.fmt.allocPrint(
            self.alloc,
            "wants {s}, got {s}",
            .{ expected_name, actual_str },
        );
        try self.appendError(msg, span, label);
    }

    fn appendFieldMismatch(self: *SemanticChecker, field: anytype, expected: types_mod.TypeInfo, actual: types_mod.TypeInfo) !void {
        const expected_str = try types_mod.formatType(self.alloc, expected);
        const actual_str = try types_mod.formatType(self.alloc, actual);
        const obj_name = try types_mod.formatType(self.alloc, types_mod.inferExprType(self, field.object));
        const msg = try std.fmt.allocPrint(self.alloc, "field `{s}` on `{s}` wants {s}, got {s}", .{
            field.name,
            obj_name,
            expected_str,
            actual_str,
        });
        try self.appendError(msg, field.object.span, try std.fmt.allocPrint(self.alloc, "field {s} on {s} is not {s} (got {s})", .{
            field.name,
            obj_name,
            expected_str,
            actual_str,
        }));
    }

    fn appendReturnMismatch(self: *SemanticChecker, span: ast.Span, expected: types_mod.TypeInfo, actual: types_mod.TypeInfo) !void {
        const expected_str = try types_mod.formatType(self.alloc, expected);
        const actual_str = try types_mod.formatType(self.alloc, actual);
        const msg = try std.fmt.allocPrint(self.alloc, "return type mismatch: wanted {s}, got {s}", .{
            expected_str,
            actual_str,
        });
        try self.appendError(msg, span, try std.fmt.allocPrint(self.alloc, "return type not {s} (got {s})", .{
            expected_str,
            actual_str,
        }));
    }

    fn appendError(self: *SemanticChecker, message: []const u8, span: ast.Span, label: []const u8) !void {
        try self.errors.append(self.alloc, .{ .@"error" = message });
        try self.errors.append(self.alloc, .{ .span = .{
            .span = span,
            .role = .primary,
            .message = try self.alloc.dupe(u8, label),
        } });
    }
};
