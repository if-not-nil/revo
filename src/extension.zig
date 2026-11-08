//!
//! baselib-ish typed host functions for `.so` extensions
//!
//! shape:
//! ```zig
//! const revo = @import("revo");
//! const extension = revo.extension;
//!
//! const Impl = struct {
//!     pub fn add(vm: *extension.VM, a: extension.ArgTypes.number, b: extension.ArgTypes.number) !extension.HostResult {
//!         return .data(extension.Value.new.num(a + b));
//!     }
//!     pub fn greet(vm: *extension.VM, name: extension.ArgTypes.string) !extension.HostResult {
//!         const bytes = extension.str(vm, name);
//!         const id = try vm.strings.own(bytes);
//!         return .data(extension.Value.new.str(id));
//!     }
//! };
//!
//! pub export const revo_native_bindings_ex = extension.bindingsFor(Impl);
//! ```
//!
//! args here are runtime-checked; callers ascribe compile-time types
//!

const std = @import("std");

const base = @import("base/root.zig");
const revo = @import("root.zig");
const specs = @import("base/specs.zig");

pub const ArgTypes = base.host.ArgTypes;
pub const ParamType = base.host.ParamType;
pub const HostFunc = base.host.HostFunc;
pub const HostFn = base.host.HostFn;
pub const HostResult = base.host.HostResult;
pub const VM = revo.VM;
pub const Value = revo.Value;

/// derive arity/param_types/unwrapping from a `fn (vm: *VM, typed args...) !HostResult` signature
/// , `ArgTypes.Optional` params become optional with defaults
pub const def = base.host.def;
/// explicit prefix types; this is where you do variadic tails
pub const define = base.host.define;
pub const defineVariadic = base.host.defineVariadic;
/// collect `pub fn`s of a struct into `[]specs.Impl`, names are decl names
pub const impls = base.host.impls;
/// checked float-to-int conversion, null when not a finite integral value
pub const numToInt = base.host.numToInt;

pub fn abiSafe(comptime f: HostFn) HostFn {
    return struct {
        fn call(args: []const Value, vm: *VM) anyerror!HostResult {
            return f(args, vm) catch |err| {
                if (err == error.OutOfMemory) {
                    return .{ .err = .{ .host_error = error.OutOfMemory } };
                }

                const atom = vm.internAtom(@errorName(err)) catch {
                    return HostResult.other("extension error name could not be interned");
                };
                return HostResult.errValue(vm, Value.new.atom(atom)) catch {
                    return HostResult.other("extension error value could not be created");
                };
            };
        }
    }.call;
}

/// max typed params per binding;
/// vm has a small-arg fast path (16)
/// so every checked arg stays out of the heap allocator
///
/// if you need more, you should use tables instead
pub const max_params = 16;

/// build a C-stable binding from a `def`-style `HostFunc`
///
/// `name` must be a comptime string (literal or decl name)
///
/// both carry a nul sentinel in the binary, which is what the host scans with `span`
/// trailing params at/after arity are marked omittable, so `ArgTypes.Optional` must trail
pub fn binding(comptime name: [:0]const u8, comptime f: HostFunc) revo.callable.HostBinding {
    const HB = revo.callable.HostBinding;
    comptime {
        if (f.arity > max_params) @compileError("extension binding arity exceeds 16");
        if (f.param_types.len > max_params) @compileError("extension binding param_types exceeds 16");
    }
    var tags: [max_params]u8 = @splat(HB.end);
    comptime var i: usize = 0;
    inline for (f.param_types) |spec| {
        // through a value: `Type.variant.method()` would resolve
        // against the tag type instead of calling the union method
        tags[i] = spec.toTag() | (if (i >= f.arity) HB.optional else 0);
        i += 1;
    }
    return .{
        .name = name,
        .fn_ptr = @ptrCast(@alignCast(abiSafe(f.func))),
        .param_types = tags,
        .total_arity = if (f.variadic) HB.unbounded else @intCast(f.param_types.len),
    };
}

/// build a null-terminated `HostBinding` table from an explicit `[]specs.Impl` list
///
/// plain structs need `bindingsFor`
pub fn bindings(comptime list: []const specs.Impl) [list.len + 1]revo.callable.HostBinding {
    var out: [list.len + 1]revo.callable.HostBinding = undefined;
    inline for (list, 0..) |imp, i| {
        // decl names and string literals both have a null sentinel in the binary
        //
        // re derive sentinel slice from raw ptr
        const zname: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(imp.name.ptr)));
        if (!std.mem.eql(u8, zname, imp.name)) {
            @compileError("extension binding name is not nul-terminated; use a string literal");
        }
        out[i] = binding(zname, imp.f);
    }
    out[list.len] = std.mem.zeroes(revo.callable.HostBinding);
    return out;
}

/// build a null-terminated `HostBinding` table from a baselib-style
/// `Impl` struct: `pub export const revo_native_bindings_ex =
/// ext.bindingsFor(Impl);`
pub fn bindingsFor(comptime S: type) [(impls(S).val.len) + 1]revo.callable.HostBinding {
    return bindings(impls(S).val);
}

// -- [helpers] ---------------------------------------------------------------
// prime area for addition contribs
// ----------------------------------------------------------------------------

/// borrowed bytes of a `ArgTypes.string` arg; valid until the next GC sweep
///
/// copy it when holding across allocations
pub fn str(vm: *VM, s: ArgTypes.string) []const u8 {
    return vm.stringValue(@backingInt(s));
}

/// nul-terminated copy of a `ArgTypes.string` arg for C interop; free with `freeZstr`
pub fn zstr(vm: *VM, s: ArgTypes.string) ![:0]const u8 {
    const bytes = str(vm, s);
    const buf = try vm.runtime.alloc.alloc(u8, bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return buf[0..bytes.len :0];
}

pub fn freeZstr(vm: *VM, z: [:0]const u8) void {
    vm.runtime.alloc.free(z.ptr[0 .. z.len + 1]);
}

/// checked `ArgTypes.number` (f64) to int conversion
/// , null when not a finite integral value representable in `I`
pub fn int(comptime I: type, n: ArgTypes.number) ?I {
    return numToInt(I, n);
}

/// box a caller-owned ptr as a resource handle
pub fn resource(vm: *VM, ptr: ?*anyopaque) !Value {
    return Value.new.resource(try vm.resources.create(ptr));
}

/// resolve a handle to its ptr; null unless a live resource
pub fn resourcePtr(vm: *VM, val: Value) ?*anyopaque {
    const id = val.asResource() orelse return null;
    const cell = vm.resources.get(id) catch return null;
    return cell.ptr;
}

/// fresh metatable with `free` installed as `__gc`, attached to the handle
/// , share the returned table across handles for named types
pub fn withGc(vm: *VM, ud: Value, name: []const u8, free: HostFn) !Value {
    const id = ud.asResource() orelse return error.TypeError;
    const fn_id = try vm.installHost(name, .{
        .arity = 1,
        .param_types = &.{.any},
        .func = free,
        .variadic = false,
        .ret_type = .any,
    });
    const mt = try vm.tables.create();
    const tbl = try vm.tables.get(mt);
    try tbl.putRawAtom(revo.CoreAtoms.atomId(.__gc), Value.new.function(fn_id), vm);
    try vm.setResourceMetatable(id, mt);
    return Value.new.table(mt);
}

// -- [test] ------------------------------------------------------------------

test bindingsFor {
    const HB = revo.callable.HostBinding;
    const S = struct {
        pub fn add(vm: *VM, a: ArgTypes.number, b: ArgTypes.number) !HostResult {
            _ = vm;
            return .data(Value.new.num(a + b));
        }
        pub fn with_opt(vm: *VM, a: ArgTypes.number, b: ArgTypes.Optional(.number, 5)) !HostResult {
            _ = vm;
            return .data(Value.new.num(a + b.value));
        }
        pub fn greet(vm: *VM, name: ArgTypes.string) !HostResult {
            _ = vm;
            _ = name;
            return .data(Value.new.nil());
        }
    };
    const table = comptime bindingsFor(S);
    try std.testing.expectEqual(@as(usize, 4), table.len);

    const num_spec: ParamType = .number;
    const str_spec: ParamType = .string;

    try std.testing.expectEqualStrings("add", std.mem.span(table[0].name));
    try std.testing.expectEqual(@as(u8, 2), table[0].total_arity);
    try std.testing.expectEqual(num_spec.toTag(), table[0].param_types[0]);
    try std.testing.expectEqual(num_spec.toTag(), table[0].param_types[1]);
    try std.testing.expectEqual(HB.end, table[0].param_types[2]);

    try std.testing.expectEqualStrings("with_opt", std.mem.span(table[1].name));
    try std.testing.expectEqual(@as(u8, 2), table[1].total_arity);
    try std.testing.expectEqual(num_spec.toTag(), table[1].param_types[0]);
    try std.testing.expectEqual(num_spec.toTag() | HB.optional, table[1].param_types[1]);
    try std.testing.expectEqual(HB.end, table[1].param_types[2]);

    try std.testing.expectEqualStrings("greet", std.mem.span(table[2].name));
    try std.testing.expectEqual(@as(u8, 1), table[2].total_arity);
    try std.testing.expectEqual(str_spec.toTag(), table[2].param_types[0]);
    try std.testing.expectEqual(HB.end, table[2].param_types[1]);

    // null terminator
    const term_name: ?[*:0]const u8 = @ptrCast(table[3].name);
    try std.testing.expect(term_name == null);
}

test bindings {
    const HB = revo.callable.HostBinding;
    const shout = struct {
        fn f(args: []const Value, vm: *VM) anyerror!HostResult {
            _ = args;
            _ = vm;
            return .data(Value.new.num(1));
        }
    }.f;
    const bound = comptime bindings(&.{
        .{ .name = "shout", .f = defineVariadic(&.{.string}, shout) },
    });
    try std.testing.expectEqual(@as(usize, 2), bound.len);
    try std.testing.expectEqualStrings("shout", std.mem.span(bound[0].name));
    try std.testing.expectEqual(HB.unbounded, bound[0].total_arity);
    const str_spec: ParamType = .string;
    try std.testing.expectEqual(str_spec.toTag(), bound[0].param_types[0]);
    try std.testing.expectEqual(HB.end, bound[0].param_types[1]);
}

test "resource binding tag" {
    const S = struct {
        fn f(_: *VM, h: ArgTypes.resource) !HostResult {
            return .data(Value.new.resource(@backingInt(h)));
        }
    };
    const f = def(S.f);
    try std.testing.expect(f.param_types[0] == .resource);
    try std.testing.expect(f.param_types[0].toTag() == 7);
    try std.testing.expect(ParamType.fromTag(7) == .resource);
}
