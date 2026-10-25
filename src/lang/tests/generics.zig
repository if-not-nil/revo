const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;

const types = lang.compiler.types;

test "non-exhaustive match" {
    try t.expectSemanticError(
        \\ let n: number = 1
        \\ let x: number = match n
        \\ | 1 => 2
        \\ | 2 => 3
    );

    // partial result match carries :nil in its type
    try t.expectSemanticError(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ let y: number = match x
        \\ | {:ok, v} => v
    );

    // wildcard match has no :nil
    try t.topNumber(
        \\ let n: number = 5
        \\ let x: number = match n
        \\ | 1 => 10
        \\ | _ => 20
        \\ x
    , 20);

    // exhaustive bool match has no :nil
    try t.topNumber(
        \\ let b = 1 == 1
        \\ let x: number = match b
        \\ | :true => 10
        \\ | :false => 20
        \\ x
    , 10);

    // exhaustive result match has no :nil
    try t.topNumber(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ let y: number = match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
        \\ y
    , 42);

    // ascribed arm can cover the subject
    try t.topNumber(
        \\ let n: number = 5
        \\ let x: number = match n
        \\ | v: number => v
        \\ x
    , 5);

    // exhaustive bool match is precise, not any
    // `let s: string` only fails when x is exactly number; any would compile
    try t.expectSemanticError(
        \\ let b = 1 == 1
        \\ let x: number = match b
        \\ | :true => 10
        \\ | :false => 20
        \\ let s: string = x
    );

    // exhaustive result match is precise, not any
    try t.expectSemanticError(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ let y = match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
        \\ let s: string = y
    );

    // never arm does not widen match to any
    try t.expectSemanticError(
        \\ type R = {:ok, number} | {:err, string}
        \\ let x: R = {:ok, 1}
        \\ let a = match x
        \\ | {:ok, v} => v
        \\ | {:err, e} => panic()
        \\ let s: string = a
    );

    // any payload propagates through match
    // annotation wins over the literal:
    // x may later hold {:ok, "str"},
    //   so v is any and the match is any
    //
    // narrowing to number would be unsound
    try t.topNumber(
        \\ type R = {:ok, any} | {:err, string}
        \\ let x: R = {:ok, 1}
        \\ let a = match x
        \\ | {:ok, v} => v
        \\ | {:err, e} => panic()
        \\ a
    , 1);

    // non-exhaustive match still yields :nil at runtime
    try t.topNil(
        \\ match 99
        \\ | 1 => 2
        \\ | 2 => 3
    );
}

test "non exhaustiveness warnings" {
    // non-exhaustive match warns w uncovered tag
    try t.expectWarning(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
    , ":err");

    // partial literal match warns for subject type
    try t.expectWarning(
        \\ let n: number = 1
        \\ match n
        \\ | 1 => 2
    , "number");

    // exhaustive match warns nothing
    try t.expectNoWarning(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
    );

    // wildcard match warns nothing"
    try t.expectNoWarning(
        \\ let n: number = 1
        \\ match n
        \\ | 1 => 2
        \\ | _ => 3
    );
}

test "dead match arms" {
    // wildcard first cuts later arms off
    try t.expectWarning(
        \\ let n: number = 1
        \\ match n
        \\ | _ => 1
        \\ | 1 => 2
    , "unreachable");

    // duplicate literal
    try t.expectWarning(
        \\ let n: number = 1
        \\ match n
        \\ | 1 => 10
        \\ | 1 => 20
        \\ | _ => 0
    , "unreachable");

    // covered tag
    try t.expectWarning(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, _} => 1
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
    , "unreachable");

    // bool-exhaustive arms kill the wildcard
    try t.expectWarning(
        \\ let b = 1 == 1
        \\ match b
        \\ | :true => 1
        \\ | :false => 2
        \\ | _ => 3
    , "unreachable");

    // disjoint pattern never fires
    try t.expectWarning(
        \\ let n: number = 1
        \\ match n
        \\ | :ok => 1
        \\ | _ => 2
    , "never matches");
}

test "comma arms" {
    try t.topString(
        \\ match 2
        \\ | 1, 2 => "hit"
        \\ | _ => "miss"
    , "hit");
    try t.topString(
        \\ match 3
        \\ | 1, 2 => "hit"
        \\ | _ => "miss"
    , "miss");
    // share bindings
    try t.topString(
        \\ type R = {:ok, string} | {:err, string}
        \\ let x: R = {:err, "boom"}
        \\ match x
        \\ | {:ok, v}, {:err, v} => v
        \\ | _ => "none"
    , "boom");
    // comma arm with guard
    try t.topString(
        \\ match 7
        \\ | 1, 2 => "low"
        \\ | v when v > 5 => "high"
        \\ | _ => "mid"
    , "high");
}

test "match warning codes" {
    try t.expectWarningCode(
        \\ let n: number = 1
        \\ match n
        \\ | _ => 1
        \\ | 1 => 2
    , "unreachable-match-arm");

    try t.expectWarningCode(
        \\ let n: number = 1
        \\ match n
        \\ | :ok => 1
        \\ | _ => 2
    , "impossible-match-arm");

    try t.expectWarningCode(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
    , "non-exhaustive-match");
}

test "match suggestion" {
    // uncovered tag becomes a named arm, not a wildcard
    try t.expectSuggestion(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
    , "| {:err, _} => :nil");

    // the suggested arm closes the warning
    try t.expectNoWarning(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => :nil
    );

    // infinite domains fall back to a wildcard arm
    try t.expectSuggestion(
        \\ let n: number = 1
        \\ match n
        \\ | 1 => 2
    , "| _ => :nil");

    try t.expectNoWarning(
        \\ type Res = {:ok, number} | {:err, string}
        \\ let x: Res = {:ok, 42}
        \\ match x
        \\ | {:ok, v} => v
        \\ | {:err, _} => 0
    );
}

test "error codes" {
    // type mismatch carries its code
    try t.expectErrorCode(
        \\ let x: number = "hi"
    , "type-mismatch");

    // unknown name carries its code
    try t.expectErrorCode("aaa\n", "unknown-name");
}

test "return type propagation: const binding with annotated fn" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ const add = fn(a: number, b: number) a + b
        \\ let x = add(3, 4)
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "return type propagation: fn five() 5" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn five() 5
        \\ let x = five()
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "annotated function return type propagates to caller via pointer" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn add(a: number, b: number) a + b
        \\ let x = add(3, 4)
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

//
// generics / type_var tests
//

test "types: type_var equality" {
    const TI = lang.compiler.types.TypeInfo;
    const a = TI{ .tag = .{ .type_var = "T" } };
    const b = TI{ .tag = .{ .type_var = "T" } };
    const c = TI{ .tag = .{ .type_var = "U" } };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(.{ .tag = .number }));
}

test "types: type_var coercion" {
    const tv = types.TypeInfo{ .tag = .{ .type_var = "T" } };
    try std.testing.expect(types.canCoerce(tv, .{ .tag = .number }));
    try std.testing.expect(types.canCoerce(.{ .tag = .number }, tv));
    try std.testing.expect(types.canCoerce(tv, .{ .tag = .any }));
    try std.testing.expect(types.canCoerce(.{ .tag = .any }, tv));
    try std.testing.expect(types.canCoerce(tv, tv));
}

test "substituteTypeParams resolves vars and sigs" {
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();

    const unbound = try types.substituteTypeParams(alloc, types.TypeInfo{ .tag = .{ .type_var = "T" } }, subst);
    try std.testing.expect(unbound.eql(.{ .tag = .any }));

    try subst.put("T", .{ .tag = .number });
    const bound = try types.substituteTypeParams(alloc, types.TypeInfo{ .tag = .{ .type_var = "T" } }, subst);
    try std.testing.expect(bound.eql(.{ .tag = .number }));

    const sig = try alloc.create(types.FunctionSignature);
    sig.* = .{
        .params = &.{types.TypeInfo{ .tag = .{ .type_var = "T" } }},
        .return_type = types.TypeInfo{ .tag = .{ .type_var = "T" } },
        .param_names = &.{"x"},
    };
    const input = types.TypeInfo{ .tag = .{ .function = sig } };
    const result = try types.substituteTypeParams(alloc, input, subst);
    try std.testing.expect(result.tag == .function);
    try std.testing.expect(result.tag.function.params.len == 1);
    try std.testing.expect(result.tag.function.params[0].eql(.{ .tag = .number }));
    try std.testing.expect(result.tag.function.return_type.eql(.{ .tag = .number }));
    alloc.destroy(sig);
    alloc.free(result.tag.function.params);
    alloc.destroy(result.tag.function);
}

test "generics identity fn enables add_imm" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn id<T>(x: T) x
        \\ let y = id(42)
        \\ y + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "generics identity fn with string compiles and runs" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn id<T>(x: T) x
        \\ id("hello")
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics compound return type {:ok, T} propagates inner type" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn wrap<T>(x: T) -> {:ok, T} {:ok, x}
        \\ let r = wrap(42)
        \\ r[1] + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics multiple type params with table return compile" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn pair<T, U>(a: T, b: U) -> {T, U}
        \\ pair(1, "hi")
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics non-inferrable type param (return-only) compiles" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn make<T>() 5
        \\ make()
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics repeated type param works" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn same<T>(a: T, b: T) a
        \\ let x = same(42, 99)
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_imm = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_imm) saw_add_imm = true;
    }
    try std.testing.expect(saw_add_imm);
}

test "explicit call-site type args resolve return types" {
    try t.topNumber(
        \\ fn make<T>() -> T 5
        \\ make<number>()
    , 5);
    try t.topNumber(
        \\ fn id<T>(x: T) -> T x
        \\ id<number>(42)
    , 42);
}

test "explicit type args work on dotted receivers" {
    try t.topNumber(
        \\ fn id<T>(x: T) -> T x
        \\ const m = {id = id}
        \\ m.id<number>(42)
    , 42);
}

test "unhugged brackets parse as comparison" {
    // `id <T>(42)` is `(id < T) > (42)`, not a generic call:
    // `T` is a type param, not a value, so this must be a semantic error
    // rather than evaluating to 42
    try t.expectSemanticError(
        \\ fn id<T>(x: T) -> T x
        \\ id <T>(42)
    );
}

test "return-only type param stays any without explicit args" {
    // T appears only in the return, so a bare call leaves it unbound (any)
    // and a string binding compiles; it still runs fine
    try t.topNumber(
        \\ fn make<T>(x) -> T return x
        \\ let y = make(1)
        \\ let s: string = y
        \\ y
    , 1);
    // shape-bound params still infer without any explicit args
    try t.expectSemanticError(
        \\ fn id<T>(x: T) x
        \\ let y = id(42)
        \\ let s: string = y
    );
}

test "implicit generics" {
    try t.topNumber(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let t = v2_new(1, 2)
        \\ t.x + t.y
    , 3);
    try t.expectSemanticError(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let t = v2_new(1, 2)
        \\ let s: string = t.x
    );
    try t.expectSemanticError(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let u: { x: string } = v2_new(1, 2)
    );
    //
    // atom and string args keep precise types
    try t.topString(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let t = v2_new(:hi, "str here")
        \\ t.y
    , "str here");
    try t.expectSemanticError(
        \\ fn v2_new(x, y) { x = x, y = y }
        \\ let t = v2_new(:hi, "str here")
        \\ let n: number = t.x
    );
    //
    // unannotated identity specializes return
    try t.topNumber(
        \\ fn id(x) x
        \\ let y = id(42)
        \\ y + 1
    , 43);
    try t.expectSemanticError(
        \\ fn id(x) x
        \\ let y = id(42)
        \\ let s: string = y
    );
    //
    // constructor field specializes"
    try t.topString(
        \\ fn Hi(field) { field = field, get_field = fn(self) self.field }
        \\ const t = Hi("hi")
        \\ t.field
    , "hi");
    try t.expectSemanticError(
        \\ fn Hi(field) { field = field, get_field = fn(self) self.field }
        \\ const t = Hi("hi")
        \\ let n: number = t.field
    );
}

//
// baselib signatures flow from the semantic checker through the
// annotation bridge into the compiler
//
