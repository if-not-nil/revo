const std = @import("std");

const revo = @import("revo");
const Value = revo.Value;
const root = @import("root.zig");
const Compiler = root.Compiler;

const cst = @import("../cst.zig");
const Node = cst.CstNode;
const Opcode = revo.opcode.Opcode;
const control = @import("control.zig");
const ir = @import("../ir/root.zig");
const locals = @import("locals.zig");
const toRegister = locals.toRegister;
const types_mod = @import("types.zig");

pub const BindingKind = enum { global, global_const, let, @"const" };

pub fn compileLocalBinding(
    self: *Compiler,
    name: []const u8,
    value: *const Node,
    mutable: bool,
    type_name: ?*const cst.CstType,
) !void {
    try self.validateName(name, value.span);
    if (!cst.isDiscardName(name)) if (locals.currentFunctionState(self)) |fn_state|
        for (fn_state.import_locals.items) |il|
            if (std.mem.eql(u8, il.name, name)) {
                try self.appendFailureReport(.ParseError, &.{
                    .{ .@"error" = "name conflicts with an import" },
                    .{ .span = .{ .span = value.span, .role = .primary, .message = name } },
                });
                return error.CompileFailed;
            };
    // fn slots can be reused if not initialized
    const vu = cst.unwrapParen(value);
    const is_fn = if (vu) |u| u.kind == .fn_def else false;

    const slot = if (is_fn)
        try locals.reuseOrDeclareLocal(self, name, mutable)
    else
        try locals.declareLocal(self, name, mutable);

    locals.reserveLocalSlots(self);

    if (vu != null and vu.?.kind == .fn_def) {
        const f = vu.?.kind.fn_def;
        const tps = try cst.tokenTexts(self.alloc, f.type_params);
        try self.compileFn(
            f.params,
            f.return_type,
            f.body,
            name,
            null,
            tps,
        );
    } else {
        // hide the binding's own name from its initializer so `x() = x()` and
        // `let x = x + 1` read the outer binding, not the fresh uninitialized slot
        try self.masking_stack.append(self.alloc, name);
        errdefer _ = self.masking_stack.pop();
        try self.compile(value, true);
        _ = self.masking_stack.pop();
    }

    locals.markLocalInitialized(self, slot);

    const inferred_type = if (type_name) |tn|
        try types_mod.evalTypeExpr(self.aliasScope(), tn)
    else
        self.annotatedType(value);

    try locals.setLocalTypeHint(self, name, inferred_type);
    if (type_name != null) {
        locals.setLocalType(self, slot, inferred_type);
        locals.setLocalTypeExplicit(self, slot);
    }

    try self.emitBind(.bind_local, slot, try toRegister(self.active_registers - 1));
}

pub fn bindDeclaredPattern(
    self: *Compiler,
    pattern: *const Node,
    source_idx: usize,
    kind: BindingKind,
) !void {
    const u = cst.unwrapParen(pattern) orelse return;
    switch (u.kind) {
        .ident => |n| {
            const name = n.tok.text;
            if (cst.isDiscardName(name)) return;
            const slot = try locals.reuseOrDeclareLocal(self, name, kind != .@"const" and kind != .global_const);
            locals.markLocalInitialized(self, slot);
            try self.emitBind(.bind_local, slot, try toRegister(source_idx));
            _ = try self.pop();
            locals.reserveLocalSlots(self);
        },
        .table => |tbl| {
            // only keyless tables destructure; keyed handled by callers
            for (tbl.entries, 0..) |entry, idx| {
                if (entry != .bare) continue;
                try control.fetchPatternElem(self, .{ .reg = source_idx }, idx);
                try bindDeclaredPattern(self, entry.bare.value, self.active_registers - 1, kind);
            }
        },

        .ascribed => |a| try bindDeclaredPattern(self, a.expr, source_idx, kind),
        else => {},
    }
}

pub fn declarePatternLocals(
    self: *Compiler,
    pattern: *const Node,
    mutable: bool,
) !void {
    const u = cst.unwrapParen(pattern) orelse return;
    switch (u.kind) {
        .ident => |n| {
            const name = n.tok.text;
            if (cst.isDiscardName(name)) return;
            _ = try locals.reuseOrDeclareLocal(self, name, mutable);
            locals.reserveLocalSlots(self);
        },
        .table => |tbl| {
            for (tbl.entries) |entry| {
                if (entry != .bare) continue;
                try declarePatternLocals(self, entry.bare.value, mutable);
            }
        },
        .ascribed => |a| try declarePatternLocals(self, a.expr, mutable),
        else => {},
    }
}

pub fn collectPatternNames(
    pattern: *const Node,
    out: *std.ArrayList([]const u8),
    alloc: std.mem.Allocator,
) !void {
    const u = cst.unwrapParen(pattern) orelse return;
    switch (u.kind) {
        .ident => |n| {
            const name = n.tok.text;
            if (cst.isDiscardName(name)) return;
            try out.append(alloc, name);
        },
        .table => |tbl| {
            for (tbl.entries) |entry| {
                if (entry != .bare) continue;
                try collectPatternNames(entry.bare.value, out, alloc);
            }
        },
        .ascribed => |a| try collectPatternNames(a.expr, out, alloc),
        else => {},
    }
}

pub fn declareGlobalPattern(
    self: *Compiler,
    pattern: *const Node,
) !void {
    const u = cst.unwrapParen(pattern) orelse return;
    switch (u.kind) {
        .ident => |n| {
            const name = n.tok.text;
            if (cst.isDiscardName(name)) return;
            try self.declared_globals.put(name, {});
        },
        .table => |tbl| {
            for (tbl.entries) |entry| {
                if (entry != .bare) continue;
                try declareGlobalPattern(self, entry.bare.value);
            }
        },
        .ascribed => |a| try declareGlobalPattern(self, a.expr),
        else => {},
    }
}

pub fn bindPattern(
    self: *Compiler,
    pattern: *const Node,
    source_idx: usize,
    kind: BindingKind,
) !void {
    const u = cst.unwrapParen(pattern) orelse return;
    switch (u.kind) {
        .ident => |n| {
            const name = n.tok.text;
            if (cst.isDiscardName(name)) return;
            const mv_dst = try locals.pushRegister(self);
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst, 0);
            try self.emit(
                if (kind == .@"const" or kind == .global_const) .store_user_global_const else .store_user_global,
                try self.vm.internAtom(name),
            );
        },
        .table => |tbl| {
            const is_mutable = kind != .@"const" and kind != .global_const;
            var idx: usize = 0;
            for (tbl.entries) |entry| {
                if (entry != .bare) continue;
                const item = entry.bare.value;
                const iu = cst.unwrapParen(item) orelse {
                    idx += 1;
                    continue;
                };
                switch (iu.kind) {
                    .ident => |n| {
                        const name = n.tok.text;
                        if (cst.isDiscardName(name)) {
                            idx += 1;
                            continue;
                        }
                        try control.fetchPatternElem(self, .{ .reg = source_idx }, idx);

                        try self.emit(
                            if (is_mutable) .store_user_global else .store_user_global_const,
                            try self.vm.internAtom(name),
                        );
                    },
                    .table, .ascribed => {
                        try control.fetchPatternElem(self, .{ .reg = source_idx }, idx);

                        try bindPattern(self, item, self.active_registers - 1, kind);
                    },
                    else => {},
                }
                idx += 1;
            }
        },
        .ascribed => |a| try bindPattern(self, a.expr, source_idx, kind),
        else => {},
    }
}

/// like bindPattern, but the names are already declared
fn storePattern(self: *Compiler, pattern: *const Node, source_idx: usize) !void {
    const u = cst.unwrapParen(pattern) orelse return;
    switch (u.kind) {
        .ident => |n| {
            const name = n.tok.text;
            if (cst.isDiscardName(name)) return;
            try self.spans.append(self.alloc, self.active_span);
            try storeIdentTop(self, name, pattern, pattern);
            return;
        },
        .table => |tbl| {
            var idx: usize = 0;
            for (tbl.entries) |entry| {
                if (entry != .bare) continue;
                const item = entry.bare.value;
                const iu = cst.unwrapParen(item);
                const patternish = if (iu) |v| v.kind == .ident or v.kind == .table or v.kind == .ascribed else false;
                if (!patternish) {
                    idx += 1;
                    continue;
                }
                try control.fetchPatternElem(self, .{ .reg = source_idx }, idx);
                try storePattern(self, item, self.active_registers - 1);
                idx += 1;
            }
        },
        .ascribed => |a| try storePattern(self, a.expr, source_idx),
        else => {},
    }
}

pub fn compileAssign(
    self: *Compiler,
    target: *const Node,
    value: *const Node,
) !void {
    if (cst.patternBareEntries(target)) |items| {
        try validateTablePatternShape(self, items, value, "assignment");
        try self.compile(value, true);
        const src_idx = self.active_registers - 1;
        return storePattern(self, target, src_idx);
    }
    return compileAssignInner(self, target, value, null);
}

pub fn compileCompound(
    self: *Compiler,
    target: *const Node,
    op: cst.BinOp,
    value: *const Node,
) !void {
    return compileAssignInner(self, target, value, op);
}

/// shared assign core: with op the old value loads first and folds through
/// computeCompoundNew, without op the value compiles directly.
/// either way NEW ends on stack top and the tail stores it
fn compileAssignInner(
    self: *Compiler,
    target: *const Node,
    value: *const Node,
    op: ?cst.BinOp,
) !void {
    const tu = cst.unwrapParen(target) orelse return self.fail(.InvalidAssignmentTarget, target, "cannot assign to nothing");
    switch (tu.kind) {
        .ident => |n| {
            const name = n.tok.text;
            if (op) |o| {
                try self.compile(target, true);
                try computeCompoundNew(self, o, target, value);
            } else try self.compile(value, true);
            try storeIdentTop(self, name, target, value);
        },
        .field => |field| {
            const fname = field.name_tok.text;
            const key_atom = try self.vm.internAtom(fname);
            try self.compile(field.object, true);
            try self.regDupe();
            if (op) |o| {
                try self.emit(.table_get_atom, key_atom);
                try computeCompoundNew(self, o, target, value);
            } else try self.compile(value, true);

            try finishAtomStore(self, field.object, key_atom, fname, value);
        },
        .dotted_index => |d| {
            // `t.0` reads element 0; assignment reuses the index path
            const key_node = try cst.allocNode(self.alloc, d.num_tok.span(), .{ .number = .{ .tok = d.num_tok, .value = d.value, .is_float = false } });
            const index_node = try cst.allocNode(self.alloc, target.span, .{ .index = .{
                .object = d.object,
                .lbracket_tok = d.dot_tok,
                .key = key_node,
                .rbracket_tok = d.dot_tok,
            } });
            return compileAssignInner(self, index_node, value, op);
        },
        .index => |index| {
            try self.compile(index.object, true);
            const ku = cst.unwrapParen(index.key);
            if (ku != null and ku.?.kind == .atom) {
                const aname = cst.atomName(ku.?.kind.atom.tok.text);
                const key_atom = try self.vm.internAtom(aname);
                try self.regDupe();
                if (op) |o| {
                    try self.emit(.table_get_atom, key_atom);
                    try computeCompoundNew(self, o, target, value);
                } else try self.compile(value, true);

                try finishAtomStore(self, index.object, key_atom, aname, value);
            } else {
                // evaluate object + key once; re-materialize them after the
                // set so the get doesn't re-evaluate either operand
                try self.compile(index.key, true);
                const obj_inst = self.value_stack.items[self.value_stack.items.len - 2];
                const key_inst = self.value_stack.items[self.value_stack.items.len - 1];
                if (op) |o| {
                    // keep the originals alive across the load: the get
                    // consumes its operands, and the later set needs them again
                    try pushPairMoves(self, obj_inst, key_inst);
                    try self.emit(.table_get, 0);
                    try computeCompoundNew(self, o, target, value);
                } else try self.compile(value, true);

                try finishIndexStore(self, index.object, index.key, obj_inst, key_inst, value);
            }
        },
        else => {
            // all bullshit like == or |
            const msg = try self.alloc.print(
                "bad assignment target: {s}",
                .{@tagName(tu.kind)},
            );
            return self.fail(.InvalidAssignmentTarget, target, msg);
        },
    }
}

pub fn validateTablePatternShape(
    self: *Compiler,
    pattern: []const cst.CstEntry,
    value: *const Node,
    context: []const u8,
) !void {
    const vu = cst.unwrapParen(value);
    if (vu == null or vu.?.kind != .table) return;
    // only array part counts
    // , hash entries dont matter
    var got: usize = 0;
    for (vu.?.kind.table.entries) |entry| {
        if (entry == .bare) got += 1;
    }

    // exact arity on the array part
    // ; hash entries dont matter
    var want: usize = 0;
    for (pattern) |entry| {
        if (entry == .bare) want += 1;
    }
    if (got == want) return;
    const msg = try self.alloc.print(
        "table {s} expects {d} items, got {d}",
        .{ context, want, got },
    );
    return self.fail(.ParseError, value, msg);
}

/// NEW is on stack top
/// . dup it and store to an ident with the same
///   const and declared checks as plain assignment
fn storeIdentTop(self: *Compiler, name: []const u8, target: *const Node, hint_node: *const Node) !void {
    try self.regDupe();
    if (locals.resolveLocal(self, name)) |slot| {
        if (locals.resolveLocalVar(self, name)) |lv| if (!lv.mutable)
            return self.fail(.CompileError, target, "reassignment to constant!");

        try self.emit(.store_local, slot);
        const inferred_type = self.annotatedType(hint_node);

        try locals.setLocalTypeHint(self, name, inferred_type);
    } else if (try locals.resolveUpvalue(self, name)) |slot| {
        const fn_state = locals.currentFunctionState(self) orelse
            return self.fail(.CompileError, target, "reassignment to constant!");

        if (!fn_state.upvalues.items[slot].mutable)
            return self.fail(.CompileError, target, "reassignment to constant!");

        try self.emit(.store_upval, slot);
    } else {
        if (self.functions.items.len == 1) {
            const atom = try self.vm.internAtom(name);
            const known = self.declared_globals.contains(name) or
                self.vm.builtin_globals.contains(atom) or
                self.vm.user_globals.contains(atom) or
                self.vm.frozen_globals.contains(atom);

            if (!known) {
                const msg = try self.alloc.print(
                    "assignment target `{s}` is not declared",
                    .{name},
                );
                return self.fail(.InvalidAssignmentTarget, target, msg);
            }

            try self.emit(.store_user_global, atom);
        } else {
            const msg = try self.alloc.print(
                "assignment target `{s}` is not declared",
                .{name},
            );

            return self.fail(.InvalidAssignmentTarget, target, msg);
        }
    }
}

/// for when stack is [OBJ, NEW]
///
/// set the atom field and reload so the expr reads back newval.
fn finishAtomStore(self: *Compiler, object: *const Node, key_atom: revo.AtomID, hint_name: []const u8, hint_node: *const Node) !void {
    try self.emit(.table_set_atom, key_atom);
    try self.emit(.table_get_atom, key_atom);
    try widenLocalTableHint(self, object, hint_name, hint_node);
}

/// fot when stack is [OBJ, KEY, NEW]
///
/// set, re-get obj+key from the saved insts
/// , and get so the expr reads back newval without re-eval
fn finishIndexStore(self: *Compiler, object: *const Node, key: *const Node, obj_inst: *ir.IrInst, key_inst: *ir.IrInst, hint_node: *const Node) !void {
    try self.emit(.table_set, 0);
    try pushPairMoves(self, obj_inst, key_inst);
    try self.emit(.table_get, 0);

    // static str keys widen like hash keys
    // ; computed keys leave the hint alone
    //   (nulling it would misguide method shadowing codegen)
    const ku = cst.unwrapParen(key);
    if (ku != null and ku.?.kind == .string) {
        try widenLocalTableHint(self, object, ku.?.kind.string.tok.text, hint_node);
    }
}

/// OLD is on stack top. folds int rhs into an immediate when both sides
/// are numeric, else compiles rhs and emits the binop.
fn computeCompoundNew(self: *Compiler, op: cst.BinOp, target: *const Node, value: *const Node) !void {
    const left_type = self.annotatedType(target);
    const right_type = self.annotatedType(value);
    const both_numeric = op != .concat and left_type.tag == .number and right_type.tag == .number;
    if (both_numeric) {
        if (root.immOpFor(op)) |op_imm| {
            if (root.immInt(value)) |k| {
                try self.emit(op_imm, k);
                return;
            }
        }
    }
    try self.compile(value, true);
    // BinOp names match Opcode names by construction; union is rejected above
    try self.emit(switch (op) {
        .@"union" => unreachable,
        inline else => |tag| @field(Opcode, @tagName(tag)),
    }, 0);
}

/// push reg copies of two earlier stack values
/// , key first so the obj dupe can claim its slot without losing thekey
fn pushPairMoves(self: *Compiler, obj_inst: *ir.IrInst, key_inst: *ir.IrInst) !void {
    const obj_dst = try locals.pushRegister(self);
    const key_dst = try locals.pushRegister(self);

    try moveInstTo(self, key_dst, key_inst);
    try moveInstTo(self, obj_dst, obj_inst);
}

// push a move of an earlier stack value into a specific top register
fn moveInstTo(self: *Compiler, dst: revo.opcode.Register, src: *ir.IrInst) !void {
    try self.spans.append(self.alloc, self.active_span);
    _ = try self.record(.move, &.{.{ .inst = src }}, true, dst, 0);
}

/// `t.f = v`: extend t's known fields so later lookups see f.
/// copy-on-write over the hint's field list, never mutates shared slices;
/// unknown shapes (plain `table`) start a fresh list. hint-scoped, so a
/// conditional add only persists inside its scope
fn widenLocalTableHint(self: *Compiler, object: *const Node, field_name: []const u8, value: *const Node) !void {
    const oname = cst.identText(object) orelse return;
    const hint = locals.resolveLocalTypeHint(self, oname) orelse return;
    if (hint.tag != .table) return;
    const field_type = self.annotatedType(value);
    const old = if (hint.tag.table.fields) |fs| fs else &[_]types_mod.RecordField{};
    var widened = hint;
    if (types_mod.findFieldIndex(old, field_name)) |i| {
        const owned = try self.alloc.dupe(types_mod.RecordField, old);
        owned[i].field_type = field_type;
        widened.tag.table.fields = owned;
    } else {
        const owned = try self.alloc.alloc(types_mod.RecordField, old.len + 1);
        @memcpy(owned[0..old.len], old);
        owned[old.len] = .{ .name = field_name, .field_type = field_type };
        widened.tag.table.fields = owned;
    }
    try locals.setLocalTypeHint(self, oname, widened);
}

pub fn compileTable(self: *Compiler, entries: []const cst.CstEntry) !void {
    try self.emit(.table_new, 0);
    var array_index: i64 = 0;
    for (entries) |entry| {
        try self.regDupe();

        // `name = v` / `:h = v` store by atom. keyless values are array
        // elements, except named fns (`fn f() ...`, `let f = fn ...`),
        // which store under their name without declaring it as a local
        // so a keyless `let x = e` stores e itself
        var atom: ?[]const u8 = null;
        var named_fn: ?NamedFnBinding = null;
        switch (entry) {
            .computed => |cc| try self.compile(try isolateEntryDecls(self, cc.key), true),
            .keyed => |k| {
                const ku = cst.unwrapParen(k.key);
                if (ku != null and ku.?.kind == .ident) {
                    atom = ku.?.kind.ident.tok.text;
                } else if (ku != null and ku.?.kind == .atom) {
                    atom = cst.atomName(ku.?.kind.atom.tok.text);
                } else try self.compile(try isolateEntryDecls(self, k.key), true);
            },
            .bare => |b| {
                if (namedFnBinding(b.value)) |nb| {
                    atom = nb.name;
                    named_fn = nb;
                } else {
                    try self.@"const"(Value.new.num(array_index));
                    array_index += 1;
                }
            },
        }

        if (atom) |name| {
            if (named_fn) |nb| {
                try self.compileFn(
                    nb.params,
                    nb.return_type,
                    nb.body,
                    name,
                    null,
                    nb.type_params,
                );
            } else {
                const value_node = switch (entry) {
                    .computed => |cc| cc.value,
                    .keyed => |k| k.value,
                    .bare => |b| b.value,
                };
                try self.compile(try isolateEntryDecls(self, value_node), true);
            }
            try self.emit(.table_set_atom, try self.vm.internAtom(name));
        } else {
            const value_node = switch (entry) {
                .computed => |cc| cc.value,
                .keyed => |k| k.value,
                .bare => |b| b.value,
            };
            try self.compile(try isolateEntryDecls(self, value_node), true);
            try self.emit(.table_set, 0);
        }
        try self.regRelease();
    }
}

const NamedFnBinding = struct {
    name: []const u8,
    params: []const cst.CstParam,
    return_type: ?*const cst.CstType,
    body: *const Node,
    type_params: []const []const u8,
};

/// the binding of a keyless `fn f ...` / `let f = fn ...` entry
fn namedFnBinding(node: *const Node) ?NamedFnBinding {
    const u = cst.unwrapParen(node) orelse return null;
    if (u.kind != .decl) return null;
    const d = u.kind.decl;
    const inner = cst.unwrapParen(d.inner) orelse return null;
    const b = if (inner.kind == .binding) inner.kind.binding else return null;
    const bt = cst.unwrapParen(b.target) orelse return null;
    if (bt.kind != .ident) return null;
    const bv = cst.unwrapParen(b.value) orelse return null;
    if (bv.kind != .fn_def) return null;
    const f = bv.kind.fn_def;
    // type_params borrow the parse arena; callers use them transiently
    return .{
        .name = bt.kind.ident.tok.text,
        .params = f.params,
        .return_type = f.return_type,
        .body = f.body,
        .type_params = &.{},
    };
}

/// entry values and computed keys that declare bindings or carry loop
/// machinery would reserve parent-frame registers or leave the value
/// stack unbalanced mid-expression
/// desyncing every positional window
/// around them,[] those compile inside a synthetic zero-param fn called
/// on the spot, so the child frame owns the slots
///
/// clean nodes come back unchanged
pub fn isolateEntryDecls(self: *Compiler, node: *const Node) !*Node {
    var visitor = IsolationVisitor{};
    visitor.visit(node);
    if (!visitor.found) return @constCast(node);

    const span = node.span;
    const fn_node = try cst.allocNode(self.alloc, span, .{ .fn_def = .{
        .fn_tok = null,
        .head = .anon,
        .kind = .@"const",
        .lt_tok = null,
        .type_params = &.{},
        .tp_commas = &.{},
        .gt_tok = null,
        .lparen_tok = cst.syntheticToken("(", span),
        .params = &.{},
        .commas = &.{},
        .rparen_tok = cst.syntheticToken(")", span),
        .arrow_tok = null,
        .return_type = null,
        .body = @constCast(node),
    } });

    const call_node = try cst.allocNode(self.alloc, span, .{ .call = .{
        .callee = fn_node,
        .lparen_tok = cst.syntheticToken("(", span),
        .args = &.{},
        .commas = &.{},
        .rparen_tok = cst.syntheticToken(")", span),
    } });
    return call_node;
}

/// does this expression declare bindings or carry loop machinery? both
/// desync the enclosing window, see isolateEntryDecls. fn bodies are
/// skipped, their frames isolate themselves already
pub const IsolationVisitor = struct {
    found: bool = false,

    pub fn visit(self: *IsolationVisitor, node: *const Node) void {
        if (self.found) return;
        const u = cst.unwrapParen(node) orelse return;
        switch (u.kind) {
            .decl, .binding, .import, .loop_expr, .for_loop, .while_loop => self.found = true,
            .do_block => |d| if (d.label_tok != null) {
                self.found = true;
            } else cst.walkCst(IsolationVisitor, self, node),
            // fn frames isolate themselves already
            .fn_def, .fn_method => {},
            else => cst.walkCst(IsolationVisitor, self, node),
        }
    }
};
