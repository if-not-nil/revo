const std = @import("std");

const lang = @import("./root.zig");
const ast = @import("./ast.zig");
const diagnostic = @import("diagnostic.zig");
const struct_layout = @import("compiler/struct_layout.zig");
const types_mod = @import("compiler/types.zig");

/// run semantic analysis; known_globals are names that exist at runtime (builtins)
/// type_map, if set, is populated with name -> type_name during analysis
pub fn analyze(
    alloc: std.mem.Allocator,
    root: *const ast.Node,
    source_name: []const u8,
    source: []const u8,
    known_globals: []const []const u8,
    type_map: ?*std.StringHashMap([]const u8),
) !?lang.Error {
    var checker = try SemanticChecker.init(alloc, source_name, source, known_globals, type_map);
    defer checker.deinit();

    _ = try checker.visit(root);
    if (checker.errors.items.len == 0) return null;

    const report = try checker.finishReport();
    return .{ .semantic = .{ .kind = .ParseError, .report = report } };
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

    fn init(alloc: std.mem.Allocator, source_name: []const u8, source: []const u8, known_globals: []const []const u8, type_map: ?*std.StringHashMap([]const u8)) !SemanticChecker {
        var checker: SemanticChecker = .{
            .alloc = alloc,
            .source_name = source_name,
            .source = source,
            .errors = try std.ArrayList(diagnostic.Part).initCapacity(alloc, 8),
            .scopes = try std.ArrayList(Scope).initCapacity(alloc, 4),
            .type_aliases = std.StringHashMap(types_mod.TypeInfo).init(alloc),
            .struct_layouts = std.StringHashMap([]const struct_layout.FieldDef).init(alloc),
            .fn_sigs = try std.ArrayList(*FnSig).initCapacity(alloc, 4),
            .return_types = try std.ArrayList(types_mod.TypeInfo).initCapacity(alloc, 4),
            .type_map = type_map,
        };
        try checker.pushScope();
        // register built-in names so they don't get flagged as undefined
        for (known_globals) |name| {
            try checker.declare(name, .any);
        }
        return checker;
    }

    fn deinit(self: *SemanticChecker) void {
        while (self.scopes.items.len != 0) self.popScope();
        var layouts = self.struct_layouts.iterator();
        while (layouts.next()) |entry| self.alloc.free(entry.value_ptr.*);
        self.struct_layouts.deinit();
        self.type_aliases.deinit();
        for (self.fn_sigs.items) |sig| {
            self.alloc.free(sig.param_names);
            self.alloc.free(sig.param_types);
            self.alloc.destroy(sig);
        }
        self.fn_sigs.deinit(self.alloc);
        self.return_types.deinit(self.alloc);
        self.errors.deinit(self.alloc);
        self.scopes.deinit(self.alloc);
    }

    fn finishReport(self: *SemanticChecker) !diagnostic.Report {
        return .{
            .parts = try self.errors.toOwnedSlice(self.alloc),
            .message = "",
            .source_name = try self.alloc.dupe(u8, self.source_name),
            .source = try self.alloc.dupe(u8, self.source),
        };
    }

    fn pushScope(self: *SemanticChecker) !void {
        try self.scopes.append(self.alloc, Scope.init(self.alloc));
    }

    fn popScope(self: *SemanticChecker) void {
        var scope = self.scopes.pop() orelse return;
        scope.deinit();
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

    pub fn inferFnType(_: *SemanticChecker, _: []const ast.FnParam, _: ?[]const u8) types_mod.TypeInfo {
        return .any;
    }

    pub fn resolveTypeName(self: *SemanticChecker, name: []const u8) types_mod.TypeInfo {
        if (std.mem.eql(u8, name, "int")) return .int;
        if (std.mem.eql(u8, name, "float")) return .float;
        if (std.mem.eql(u8, name, "number")) return .{
            .@"union" = &.{
                .{ .name = "", .types = &.{.int} },
                .{ .name = "", .types = &.{.float} },
            },
        };
        if (std.mem.eql(u8, name, "string")) return .string;
        if (std.mem.eql(u8, name, "bool")) return .bool;
        if (std.mem.eql(u8, name, "void")) return .void;
        if (std.mem.eql(u8, name, "any")) return .any;
        if (name.len > 0 and name[0] == ':') return .{ .atom = name };
        if (self.type_aliases.get(name)) |aliased| return aliased;
        if (self.struct_layouts.get(name) != null) return .{ .struct_type = name };
        return .{ .struct_type = name };
    }

    fn evalTypeExpr(self: *SemanticChecker, node: *const ast.Node) !types_mod.TypeInfo {
        return try types_mod.evalTypeExpr(self, node);
    }

    fn inferExprType(self: *SemanticChecker, node: *const ast.Node) types_mod.TypeInfo {
        return switch (node.expr) {
            .struct_def => |def| .{ .struct_type = def.name },
            .type_alias => .void,
            .fn_expr => .any,
            else => types_mod.inferExprType(self, node),
        };
    }

    pub fn inferCallReturnType(self: *SemanticChecker, callee: *const ast.Node, args: []const *ast.Node) types_mod.TypeInfo {
        _ = args;
        const callee_type = self.inferExprType(callee);
        if (callee_type == .function) return callee_type.function.return_type;
        if (callee.expr == .ident) {
            if (self.lookup(callee.expr.ident)) |t| {
                if (t == .function) return t.function.return_type;
            }
        }
        return .any;
    }

    pub fn inferFieldType(self: *SemanticChecker, object: *const ast.Node, name: []const u8) types_mod.TypeInfo {
        return switch (self.inferExprType(object)) {
            .struct_type => |struct_name| blk: {
                const layout = self.struct_layouts.get(struct_name) orelse break :blk .any;
                for (layout) |f| if (std.mem.eql(u8, f.name, name)) break :blk if (f.field_type != .any) f.field_type else if (f.type_name) |tn| self.resolveTypeName(tn) else .any;
                break :blk .any;
            },
            .string => if (std.mem.eql(u8, name, "len")) .int else .any,
            else => .any,
        };
    }

    fn makeFnSig(self: *SemanticChecker, fn_expr: anytype) !*FnSig {
        var param_names = try std.ArrayList([]const u8).initCapacity(self.alloc, fn_expr.params.len);
        defer param_names.deinit(self.alloc);
        var param_types = try std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, fn_expr.params.len);
        defer param_types.deinit(self.alloc);
        for (fn_expr.params) |p| {
            try param_names.append(self.alloc, p.name);
            try param_types.append(self.alloc, if (p.type_name) |tn| self.resolveTypeName(tn) else .any);
        }
        const params_slice = try param_types.toOwnedSlice(self.alloc);
        const names_slice = try param_names.toOwnedSlice(self.alloc);
        const ret = if (fn_expr.return_type) |rt| self.resolveTypeName(rt) else .any;
        const sig_ptr = try self.alloc.create(FnSig);
        sig_ptr.* = .{
            .param_names = names_slice,
            .param_types = params_slice,
            .return_type = ret,
            .sig = .{
                .params = params_slice,
                .return_type = ret,
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
            else => self.inferExprType(node),
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
        return self.analyzeNode(node);
    }

    fn analyzeBlock(self: *SemanticChecker, exprs: []const *ast.Node, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        try self.pushScope();
        defer self.popScope();
        var last: types_mod.TypeInfo = .void;
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
        const t = self.evalTypeExpr(alias.type_expr) catch .any;
        try self.type_aliases.put(alias.name, t);
        return .void;
    }

    fn analyzeStruct(self: *SemanticChecker, def: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        var seen = std.StringHashMap(void).init(self.alloc);
        defer seen.deinit();
        var fields = try std.ArrayList(struct_layout.FieldDef).initCapacity(self.alloc, def.items.len);
        errdefer fields.deinit(self.alloc);

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
                try fields.append(self.alloc, .{
                    .name = field.name,
                    .type_name = field.type_name,
                    .field_type = if (field.type_name) |tn| self.resolveTypeName(tn) else .any,
                });
            },
            .binding => |b| {
                _ = try self.analyzeBinding(b, b.target.span);
            },
        };

        const slice = try fields.toOwnedSlice(self.alloc);
        if (self.struct_layouts.fetchRemove(def.name)) |kv| self.alloc.free(kv.value);
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
        if (binding.target.expr != .ident) return .void;
        const name = binding.target.expr.ident;
        if (binding.value.expr == .fn_expr) {
            const sig = try self.makeFnSig(binding.value.expr.fn_expr);
            const fn_type: types_mod.TypeInfo = .{ .function = &sig.sig };
            if (binding.type_name) |type_name| {
                const expected = self.resolveTypeName(type_name);
                if (!types_mod.canCoerce(fn_type, expected)) {
                    try self.appendTypeMismatch(
                        binding.target.span,
                        name,
                        type_name,
                        expected,
                        fn_type,
                        "not",
                    );
                }
            }
            try self.declare(name, fn_type);
            _ = try self.analyzeFnBody(binding.value.expr.fn_expr, sig);
            return fn_type;
        }

        const value_type = try self.analyzeNode(binding.value);
        if (binding.type_name) |type_name| {
            const expected = self.resolveTypeName(type_name);
            if (!types_mod.canCoerce(value_type, expected)) {
                try self.appendTypeMismatch(
                    binding.target.span,
                    name,
                    type_name,
                    expected,
                    value_type,
                    "not",
                );
            }
        }

        try self.declare(name, value_type);
        return value_type;
    }

    fn analyzeAssign(self: *SemanticChecker, assign: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        const value_type = try self.analyzeNode(assign.value);
        switch (assign.target.expr) {
            .ident => |name| {
                if (self.lookup(name)) |expected| {
                    if (!types_mod.canCoerce(value_type, expected)) {
                        try self.appendTypeMismatch(
                            assign.value.span,
                            name,
                            types_mod.typeName(expected),
                            expected,
                            value_type,
                            "not",
                        );
                    }
                    try self.declare(name, expected);
                }
            },
            .field => |field| {
                const object_type = self.inferExprType(field.object);
                if (object_type == .struct_type) {
                    const layout = self.struct_layouts.get(object_type.struct_type) orelse return .void;
                    for (layout) |f| {
                        if (!std.mem.eql(u8, f.name, field.name)) continue;
                        if (!types_mod.canCoerce(value_type, f.field_type)) {
                            try self.appendFieldMismatch(field, f.field_type, value_type);
                        }
                        return .void;
                    }
                }
            },
            else => {},
        }
        return .void;
    }

    fn analyzeReturn(self: *SemanticChecker, val: ?*ast.Node, span: ast.Span) !types_mod.TypeInfo {
        const expr = val orelse return .void;
        const actual = try self.analyzeNode(expr);
        const expected = if (self.return_types.items.len != 0) self.return_types.items[self.return_types.items.len - 1] else .any;
        if (expected != .any and !types_mod.canCoerce(actual, expected)) {
            try self.appendReturnMismatch(span, expected, actual);
        }
        return .void;
    }

    fn analyzeCall(self: *SemanticChecker, call: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        const callee_type = self.inferExprType(call.callee);
        if (call.callee.expr == .ident and callee_type == .function) {
            const sig = callee_type.function.*;
            if (call.args.len != sig.params.len) {
                const label = blk: {
                    if (call.args.len > sig.params.len) {
                        break :blk try std.fmt.allocPrint(self.alloc, "{d} extra args", .{
                            call.args.len -| sig.params.len,
                        });
                    } else break :blk try std.fmt.allocPrint(self.alloc, "{d} missing args", .{
                        sig.params.len -| call.args.len,
                    });
                };
                try self.appendError(
                    try std.fmt.allocPrint(self.alloc, "`{s}` wants {d} arguments, got {d}", .{
                        call.callee.expr.ident,
                        sig.params.len,
                        call.args.len,
                    }),
                    call.callee.span,
                    label,
                );
            }
            const count = @min(call.args.len, sig.params.len);
            for (0..count) |i| {
                const actual = try self.analyzeNode(call.args[i]);
                const expected = sig.params[i];
                if (!types_mod.canCoerce(actual, expected)) {
                    const msg = try std.fmt.allocPrint(self.alloc, "argument {d} to `{s}` wants {s}, got {s}", .{
                        i + 1,
                        call.callee.expr.ident,
                        types_mod.typeName(expected),
                        types_mod.typeName(actual),
                    });
                    try self.appendError(
                        msg,
                        call.args[i].span,
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

    fn analyzeIf(self: *SemanticChecker, v: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        _ = try self.analyzeNode(v.condition);
        const then_type = try self.analyzeNode(v.then_expr);
        if (v.else_expr) |else_expr| {
            const else_type = try self.analyzeNode(else_expr);
            if (!then_type.eql(else_type) and then_type != .any and else_type != .any) {
                try self.appendError(
                    try std.fmt.allocPrint(self.alloc, "if/else branches must have matching types, got {s} and {s}", .{
                        types_mod.typeName(then_type),
                        types_mod.typeName(else_type),
                    }),
                    v.then_expr.span,
                    try std.fmt.allocPrint(self.alloc, "branch mismatch: {s} vs {s}", .{
                        types_mod.typeName(then_type),
                        types_mod.typeName(else_type),
                    }),
                );
            }
            return if (then_type == .any) else_type else then_type;
        }
        return .void;
    }

    fn appendTypeMismatch(
        self: *SemanticChecker,
        span: ast.Span,
        name: []const u8,
        expected_name: []const u8,
        expected: types_mod.TypeInfo,
        actual: types_mod.TypeInfo,
        label_prefix: []const u8,
    ) !void {
        _ = label_prefix; // autofix
        const msg = try std.fmt.allocPrint(self.alloc, "`{s}` wants {s}, got {s}", .{
            name,
            expected_name,
            types_mod.typeName(actual),
        });
        const label = try std.fmt.allocPrint(
            self.alloc,
            "wants {s}, got {s}",
            .{ expected_name, types_mod.typeName(actual) },
        );
        try self.appendError(msg, span, label);
        _ = expected;
    }

    fn appendFieldMismatch(self: *SemanticChecker, field: anytype, expected: types_mod.TypeInfo, actual: types_mod.TypeInfo) !void {
        const msg = try std.fmt.allocPrint(self.alloc, "field `{s}` on `{s}` expected {s}, got {s}", .{
            field.name,
            types_mod.typeName(self.inferExprType(field.object)),
            types_mod.typeName(expected),
            types_mod.typeName(actual),
        });
        try self.appendError(msg, field.object.span, try std.fmt.allocPrint(self.alloc, "field {s} on {s} is not {s} (got {s})", .{
            field.name,
            types_mod.typeName(self.inferExprType(field.object)),
            types_mod.typeName(expected),
            types_mod.typeName(actual),
        }));
    }

    fn appendReturnMismatch(self: *SemanticChecker, span: ast.Span, expected: types_mod.TypeInfo, actual: types_mod.TypeInfo) !void {
        const msg = try std.fmt.allocPrint(self.alloc, "return type mismatch: wanted {s}, got {s}", .{
            types_mod.typeName(expected),
            types_mod.typeName(actual),
        });
        try self.appendError(msg, span, try std.fmt.allocPrint(self.alloc, "return type not {s} (got {s})", .{
            types_mod.typeName(expected),
            types_mod.typeName(actual),
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
