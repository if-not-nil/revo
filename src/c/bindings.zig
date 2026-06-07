//
// auto-generate revo.h from callconv(.c) exports
//
const std = @import("std");
const Allocator = std.mem.Allocator;

const Function = struct {
    name: []const u8,
    sig: []const u8,
    category: Category,

    const Category = enum {
        revo,
        erevo,
    };
};

const TypeTranslation = struct {
    zig: []const u8,
    c: []const u8,
};

const TRANSLATOR = [_]TypeTranslation{
    .{ .zig = "u64", .c = "uint64_t" },
    .{ .zig = "usize", .c = "size_t" },
    .{ .zig = "void", .c = "void" },
    .{ .zig = "bool", .c = "int" },
    .{ .zig = "*anyopaque", .c = "void*" },
    .{ .zig = "?*anyopaque", .c = "void*" },
    .{ .zig = "[*:0]const u8", .c = "const char*" },
    .{ .zig = "[*]const u8", .c = "const char*" },
    .{ .zig = "?[*]const u8", .c = "const char*" },
    .{ .zig = "?*ErevoVM", .c = "ErevoVM*" },
    .{ .zig = "?*ErevoProgram", .c = "ErevoProgram*" },
    .{ .zig = "?*ErevoData", .c = "ErevoData*" },
    .{ .zig = "CRevoData", .c = "RevoData" },
    .{ .zig = "[*]const CRevoData", .c = "const RevoData*" },
    .{ .zig = "ErevoData", .c = "RevoData" },
};

/// builds revo.h
pub fn data(allocator: Allocator) !std.ArrayList(u8) {
    var header = try std.ArrayList(u8).initCapacity(allocator, 4096);
    errdefer header.deinit(allocator);

    try header.appendSlice(allocator,
        \\// this file, revo.h is public domain
        \\// auto-generated, editing is futile
        \\#ifndef REVO_FFI_H
        \\#define REVO_FFI_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
        \\
    );

    var functions = try std.ArrayList(Function).initCapacity(allocator, 32);
    defer {
        for (functions.items) |func| {
            allocator.free(func.name);
            allocator.free(func.sig);
        }
        functions.deinit(allocator);
    }

    inline for (.{ "ffi.zig", "erevo.zig" }) |mod| {
        const source = @embedFile(mod);
        const source_z = try allocator.dupeZ(u8, source);
        defer allocator.free(source_z);

        const category: Function.Category = if (std.mem.endsWith(u8, mod, "ffi.zig")) .revo else .erevo;
        try parseModuleForCallconvC(allocator, source_z, &functions, category);
    }

    // sort by category, then by name
    std.mem.sort(Function, functions.items, {}, struct {
        pub fn lessThan(_: void, a: Function, b: Function) bool {
            if (a.category != b.category) {
                return @intFromEnum(a.category) < @intFromEnum(b.category);
            }
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    try header.appendSlice(allocator,
        \\typedef struct {
        \\  uint64_t tag;
        \\  uint64_t value;
        \\} RevoData;
        \\
        \\// matches internal order
        \\typedef enum {
        \\  revo_number = 0,
        \\  revo_string,
        \\  revo_atom,
        \\  revo_function,
        \\  revo_table,
        \\  revo_tuple,
        \\} RevoType;
        \\
        \\// guaranteed to be of these ids
        \\typedef enum {
        \\  ra_nil,
        \\  ra_missing,
        \\  ra_undef,
        \\  ra_none,
        \\  ra_no_result,
        \\  ra_false,
        \\  ra_true,
        \\  ra_range,
        \\  ra_ok,
        \\  ra_err,
        \\  ra_some,
        \\} RevoAtom;
        \\
        \\// helpers for often-used values
        \\#define revo_nil() (RevoData){.tag = revo_atom, .value = ra_nil}
        \\#define revo_bool(v) (RevoData){.tag = revo_atom, .value = v ? ra_true : ra_false}
        \\#define R_STRING(id) (RevoData){.tag = revo_string, .value = id}
        \\static inline RevoData revo_num(double n) { RevoData d; d.tag = revo_number; union { uint64_t u; double f; } u = { .f = n }; d.value = u.u; return d; }
        \\static inline RevoData revo_atom_val(uint64_t id) { RevoData d; d.tag = revo_atom; d.value = id; return d; }
        \\static inline double revo_num_value(RevoData d) { union { uint64_t u; double f; } u = { .u = d.value }; return u.f; }
        \\static inline uint64_t revo_string_id(RevoData d) { return d.value; }
        \\static inline uint64_t revo_table_id(RevoData d) { return d.value; }
        \\static inline uint64_t revo_tuple_id(RevoData d) { return d.value; }
        \\static inline int revo_is_nil(RevoData d) { return d.tag == revo_atom && d.value == ra_nil; }
        \\static inline int revo_is_number(RevoData d) { return d.tag == revo_number; }
        \\static inline int revo_is_string(RevoData d) { return d.tag == revo_string; }
        \\static inline int revo_is_atom(RevoData d) { return d.tag == revo_atom; }
        \\static inline int revo_is_table(RevoData d) { return d.tag == revo_table; }
        \\static inline int revo_is_tuple(RevoData d) { return d.tag == revo_tuple; }
        \\static inline int revo_is_bool(RevoData d) { return d.tag == revo_atom && (d.value == ra_true || d.value == ra_false); }
        \\
        \\// function ptr type
        \\typedef void (*RevoFn)(void *vm, size_t argc, RevoData *argv, RevoData *out_result);
        \\
        \\// function binding
        \\typedef struct {
        \\  const char *name;
        \\  RevoFn fn;
        \\} RevoBinding;
        \\
    );

    try header.appendSlice(allocator,
        \\// ffi:
        \\//   intern a string -> returns stable id
        \\//   ptr must stay valid for the duration of the call
        \\//   revo_string_data / revo_string_length read back interned strings
        \\
    );

    var last_category: ?Function.Category = null;
    for (functions.items) |func| {
        if (func.category != last_category) blk: {
            last_category = func.category;
            if (func.category != .erevo) break :blk;
            try header.appendSlice(allocator,
                \\
                \\// embedding api
                \\typedef struct ErevoVM ErevoVM;
                \\typedef struct ErevoProgram ErevoProgram;
                \\typedef RevoData ErevoData;
                \\typedef RevoType ErevoType;
                \\
                \\
            );
        }

        try header.appendSlice(allocator, func.sig);
        try header.appendSlice(allocator, ";\n");
    }

    try header.appendSlice(allocator,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif
        \\
    );

    return header;
}

fn parseModuleForCallconvC(
    allocator: Allocator,
    source: [:0]const u8,
    functions: *std.ArrayList(Function),
    category: Function.Category,
) !void {
    var ast = try std.zig.Ast.parse(allocator, source, .zig);
    defer ast.deinit(allocator);

    const root_declarations = ast.rootDecls();
    const nodes = ast.nodes;

    for (root_declarations) |decl_idx| {
        const decl_idx_val = @intFromEnum(decl_idx);
        const decl_tag = nodes.items(.tag)[decl_idx_val];

        const is_function = switch (decl_tag) {
            .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple, .fn_decl => true,
            else => false,
        };

        if (!is_function) continue;

        var param_buffer: [1]std.zig.Ast.Node.Index = undefined;
        const fn_proto = ast.fullFnProto(&param_buffer, decl_idx) orelse continue;

        // must have callconv(.c)
        if (fn_proto.ast.callconv_expr.unwrap()) |conv| {
            if (!std.mem.eql(u8, ".c", ast.getNodeSource(conv))) continue;
        } else continue;

        const name_token = fn_proto.name_token orelse continue;
        const fn_name = ast.tokenSlice(name_token);

        const expected_prefix = if (category == .revo) "revo_" else "erevo_";
        if (!std.mem.startsWith(u8, fn_name, expected_prefix)) continue;

        try functions.append(allocator, .{
            .name = try allocator.dupe(u8, fn_name),
            .sig = try buildSignature(allocator, fn_name, fn_proto, &ast),
            .category = category,
        });
    }
}

fn buildSignature(
    allocator: Allocator,
    fn_name: []const u8,
    fn_proto: std.zig.Ast.full.FnProto,
    ast: *std.zig.Ast,
) ![]const u8 {
    const return_type_src = if (fn_proto.ast.return_type.unwrap()) |ret_node|
        ast.getNodeSource(ret_node)
    else
        "void";
    const return_type = try translateType(allocator, return_type_src);
    defer allocator.free(return_type);

    var params = try std.ArrayList(ParamInfo).initCapacity(allocator, 8);
    defer {
        for (params.items) |p| {
            allocator.free(p.ty);
            if (p.name) |n| allocator.free(n);
        }
        params.deinit(allocator);
    }

    var param_iter = fn_proto.iterate(ast);
    while (param_iter.next()) |param| {
        const param_type_src = if (param.type_expr) |type_node|
            ast.getNodeSource(type_node)
        else
            "";

        const param_type = try translateType(allocator, param_type_src);
        const param_name = if (param.name_token) |name_tok|
            try allocator.dupe(u8, ast.tokenSlice(name_tok))
        else
            null;

        try params.append(allocator, .{
            .ty = param_type,
            .name = param_name,
        });
    }

    // sig
    var sig = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer sig.deinit(allocator);

    try sig.appendSlice(allocator, return_type);
    try sig.appendSlice(allocator, " ");
    try sig.appendSlice(allocator, fn_name);
    try sig.appendSlice(allocator, "(");

    if (params.items.len == 0) {
        // should be the correct way to do so
        try sig.appendSlice(allocator, "void");
    } else {
        for (params.items, 0..) |param, i| {
            // for RevoData revo_table_get(void* vm, uint64_t table_id, RevoData key);,

            // RevoData
            const ty = std.mem.trim(u8, param.ty, " ");
            try sig.appendSlice(allocator, ty);

            // revo_table_get
            if (param.name) |name| {
                try sig.appendSlice(allocator, " ");
                try sig.appendSlice(allocator, name);
            }

            // (void* vm, uint64_t table_id, RevoData key);
            if (i < params.items.len - 1) {
                try sig.appendSlice(allocator, ", ");
            }
        }
    }

    try sig.appendSlice(allocator, ")");

    return try allocator.dupe(u8, sig.items);
}

const ParamInfo = struct {
    ty: []const u8,
    name: ?[]const u8,
};

fn translateType(allocator: Allocator, zig_type: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, zig_type, " \t\n");

    // exact match first
    for (TRANSLATOR) |entry| {
        if (std.mem.eql(u8, trimmed, entry.zig)) {
            return try allocator.dupe(u8, entry.c);
        }
    }

    // prefix match for pointer types
    for (TRANSLATOR) |entry| {
        if (std.mem.startsWith(u8, trimmed, entry.zig)) {
            return try allocator.dupe(u8, entry.c);
        }
    }

    // fallback: pass through as-is
    return try allocator.dupe(u8, trimmed);
}
