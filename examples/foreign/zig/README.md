# zig extensions in revo

run:

```sh
zig build && cp zig-out/lib/libzrevo.* ./zrevo.so
revo ./extension.rv
```

see docs:

```sh
$ revo doc .

top-level

  fn zadd(a: number, b: number) -> number
    add a + b

  fn zconcat(parts: table, sep: string) -> string
    get a string of parts separated by separator

  fn zecho(s: string) -> string
    echo s

  fn zsetglobal(name: string, value) -> number
    set global called name to value
```

## writing a native zig extension

native extensions export functions that match the `HostFn` signature:
`(args: []const Data, vm: *VM) anyerror!HostResult`

in it, are:
- actual error handling via `anyerror!HostResult`
    this means you can use `try` anywhere and return any
- arity & type checking by vm (you don't always have to do it manually, just setting up a .d.rv will typecheck at compile-time)
- access to the actual full revo `*VM` (for string interning, table ops, etc.)

### example

```zig
const revo = @import("revo");
const HostBinding = revo.HostBinding;
const HostResult = revo.std_lib.HostResult;
const Data = revo.Data;
const VM = revo.VM;

fn add(args: []const Data, _: *VM) anyerror!HostResult {
    if (args.len < 2) return HostResult.errArity(args.len, 2);
    const a = args[0].asNum() orelse return HostResult.errType(0, "number", "other");
    const b = args[1].asNum() orelse return HostResult.errType(1, "number", "other");
    return HostResult.data(Data.new.num(a + b));
}

pub export const revo_native_bindings = [_]HostBinding{
    .{ .name = "add", .fn_ptr = @ptrCast(&add), .arity = 2, .variadic = false },
    std.mem.zeroes(HostBinding),
};
```

### returning values

**just values**
```zig
// success
return HostResult.data(Data.new.num(42));
return HostResult.data(Data.new.str(string_id));
return HostResult._bool(true);

// error with arity info
return HostResult.errArity(got, expected);

// error with type info
return HostResult.errType(arg_index, "expected_type", "got_type");

// generic error
return HostResult.other("something went wrong");
```

**error tables**

### accessing the vm

```zig
fn echo(args: []const Data, vm: *VM) anyerror!HostResult {
    const id = args[0].asString() orelse return HostResult.errType(0, "string", "other");
    const bytes = vm.stringValue(id);
    // intern a new string
    const new_id = revo.ffi.revo_intern(@ptrCast(vm), @intFromPtr(bytes.ptr), bytes.len);
    return HostResult.data(Data.new.str(new_id));
}
```

### exporting bindings

```zig
pub export const revo_native_bindings = [_]HostBinding{
    .{ .name = "func_name", .fn_ptr = @ptrCast(&func_name), .arity = N, .variadic = false },
    std.mem.zeroes(HostBinding),  // null terminator
};
```

the vm looks up `revo_native_bindings` from the `.so`/`.dylib` and registers each
entry as a host function. the `arity` field is used for runtime arity checking.

### type manifest (.d.rv)

the sibling `<stem>.d.rv` file provides compiletime type info for revo code that
imports the extension. it's optional but recommended:

```rv
pub declare add = fn(a: number, b: number) -> number
pub declare echo = fn(s: string) -> string
```

### build setup

the extension's `build.zig.zon` should depend on revo:

```zig
.dependencies = .{
    .revo = .{ .path = "../../.." },
},
```

and `build.zig` should create a dynamic library with the revo module:

```zig
const ext = b.addLibrary(.{
    .name = "zrevo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("functions.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "revo", .module = revo_dep.module("revo") },
        },
    }),
    .linkage = .dynamic,
});
```
