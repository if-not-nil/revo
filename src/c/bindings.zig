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
    .{ .zig = "Data", .c = "RevoData" },
    .{ .zig = "*Data", .c = "RevoData*" },
    .{ .zig = "[*]const Data", .c = "const RevoData*" },
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
        \\#include <string.h>
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
        const source_z = try allocator.dupeSentinel(u8, source, 0);
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
        \\// a revo value, nanboxed in a single u64
        \\typedef uint64_t RevoData;
        \\
        \\// type tags; they are the stored tag nibbles (bits 51-48 of the box)
        \\typedef enum {
        \\  revo_number = 0,
        \\  revo_string = 8,
        \\  revo_atom = 9,
        \\  revo_function = 10,
        \\  revo_table = 11,
        \\  revo_foreign = 15,
        \\} RevoType;
        \\
        \\// guaranteed to be of these ids
        \\typedef enum {
        \\  ra_nil,
        \\  ra_missing,
        \\  ra_undef,
        \\  ra_none,
        \\  ra_no_result,
        \\  ra_no,
        \\  ra_false,
        \\  // false atoms are all which are above above
        \\  ra_true,
        \\  ra_range,
        \\  ra_ok,
        \\  ra_err,
        \\  ra_some,
        \\} RevoAtom;
        \\
        \\// nanbox layout: numbers are raw f64 bits, boxed values are
        \\// (REVO_BOX_TAG | (type << 48) | id), so the payload of a boxed
        \\// value is an intern id, never a pointer
        \\#define REVO_BOX_TAG 0x7FF8000000000000ULL
        \\#define REVO_TAG_SHIFT 48
        \\#define REVO_TAG_MASK 0xFULL
        \\#define REVO_PAYLOAD_MASK 0x0000FFFFFFFFFFFFULL
        \\
        \\// helpers for often-used values
        \\#define revo_nil() revo_atom_val(ra_nil)
        \\#define revo_bool(v) revo_atom_val((v) ? ra_true : ra_false)
        \\#define revo_string(id) ((RevoData)(REVO_BOX_TAG | ((uint64_t)revo_string << REVO_TAG_SHIFT) | (id)))
        \\#define revo_table(id) ((RevoData)(REVO_BOX_TAG | ((uint64_t)revo_table << REVO_TAG_SHIFT) | (id)))
        \\#define revo_function(id) ((RevoData)(REVO_BOX_TAG | ((uint64_t)revo_function << REVO_TAG_SHIFT) | (id)))
        \\static inline int revo_type(RevoData d) {
        \\  return (d & 0xFFF8000000000000ULL) == REVO_BOX_TAG ? (int)((d >> REVO_TAG_SHIFT) & REVO_TAG_MASK) : revo_number;
        \\}
        \\static inline RevoData revo_num(double n) { union { uint64_t u; double f; } u = { .f = n }; return u.u; }
        \\static inline RevoData revo_atom_val(uint64_t id) { return (RevoData)(REVO_BOX_TAG | ((uint64_t)revo_atom << REVO_TAG_SHIFT) | id); }
        \\static inline double revo_num_value(RevoData d) { union { uint64_t u; double f; } u = { .u = d }; return u.f; }
        \\static inline uint64_t revo_string_id(RevoData d) { return d & REVO_PAYLOAD_MASK; }
        \\static inline uint64_t revo_atom_id(RevoData d) { return d & REVO_PAYLOAD_MASK; }
        \\static inline uint64_t revo_table_id(RevoData d) { return d & REVO_PAYLOAD_MASK; }
        \\static inline uint64_t revo_function_id(RevoData d) { return d & REVO_PAYLOAD_MASK; }
        \\static inline int revo_is_nil(RevoData d) { return revo_type(d) == revo_atom && (d & REVO_PAYLOAD_MASK) == ra_nil; }
        \\static inline int revo_is_number(RevoData d) { return revo_type(d) == revo_number; }
        \\static inline int revo_is_string(RevoData d) { return revo_type(d) == revo_string; }
        \\static inline int revo_is_atom(RevoData d) { return revo_type(d) == revo_atom; }
        \\static inline int revo_is_function(RevoData d) { return revo_type(d) == revo_function; }
        \\static inline int revo_is_table(RevoData d) { return revo_type(d) == revo_table; }
        \\static inline int revo_is_bool(RevoData d) { return revo_is_atom(d) && ((d & REVO_PAYLOAD_MASK) == ra_true || (d & REVO_PAYLOAD_MASK) == ra_false); }
        \\static inline int revo_bool_val(RevoData d) { return revo_is_bool(d) ? ((d & REVO_PAYLOAD_MASK) == ra_true ? 1 : 0) : 0; }
        \\
        \\// function ptr type
        \\typedef void (*RevoFn)(void *vm, size_t argc, RevoData *argv, RevoData *out_result);
        \\
        \\// function binding; the typed interface lives in a sibling
        \\// `<stem>.d.rv` manifest, not here
        \\typedef struct {
        \\  const char *name;
        \\  RevoFn fn;
        \\} RevoBinding;
        \\
    );

    try header.appendSlice(allocator,
        \\// ffi:
        \\//   intern a string -> returns stable id
        \\//   ptr must stay valid for the duration of the call and is not
        \\//   nul-terminated (get the length from revo_string_length)
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
        \\// c-string convenience wrappers
        \\static inline RevoData revo_getglobal_cstr(void* vm, const char* name) {
        \\  return revo_getglobal(vm, (uint64_t)(uintptr_t)name, strlen(name));
        \\}
        \\static inline void revo_setglobal_cstr(void* vm, const char* name, RevoData value) {
        \\  revo_setglobal(vm, (uint64_t)(uintptr_t)name, strlen(name), value);
        \\}
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
            // for bool revo_table_get(void* vm, RevoData table, RevoData key, RevoData* out);,

            // RevoData
            const ty = std.mem.trim(u8, param.ty, " ");
            try sig.appendSlice(allocator, ty);

            // revo_table_get
            if (param.name) |name| {
                try sig.appendSlice(allocator, " ");
                try sig.appendSlice(allocator, name);
            }

            // (void* vm, RevoData table, RevoData key, RevoData* out);
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
