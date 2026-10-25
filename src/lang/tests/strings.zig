const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;

test "field assignment works" {
    try t.topTrue(
        \\ const sys = {answer = 41}
        \\ sys.answer = 1
        \\ sys.answer
    );
    try t.topTrue(
        \\ const sys = {a = {b = 1}}
        \\ sys.a.b = 2
        \\ sys.a.b == 2
    );
    try t.topNumber(
        \\ const sys = {a = 1}
        \\ sys.a = sys.a + 1
        \\ sys.a
    , 2);
}

test "string conversion metamethods __tostring" {
    try t.topString(
        \\ const mt = {__tostring = fn(self) "custom"}
        \\ const t = set_meta({a = 1}, mt)
        \\ string(t)
    , "custom");
    try t.topString(
        \\ const mt = {__tostring = fn(self) "42"}
        \\ const t = set_meta({}, mt)
        \\ string(t)
    , "42");
}

test "display formatting uses __display and falls back to __tostring" {
    try t.topString(
        \\ const mt = {__display = fn(self) "visible", __tostring = fn(self) "hidden"}
        \\ const t = set_meta({}, mt)
        \\ fmt("%v", t)
    , "visible");

    try t.topString(
        \\ const mt = {__tostring = fn(self) "fallback"}
        \\ const t = set_meta({}, mt)
        \\ fmt("%v", t)
    , "fallback");
}

test "string interpolation uses formatting modes" {
    try t.topString(
        \\ const mt = {__display = fn(self) "visible", __debug = fn(self) "debug"}
        \\ const value = set_meta({}, mt)
        \\ "value = #{value}"
    , "value = visible");
    try t.topString(
        \\ const mt = {__display = fn(self) "visible", __debug = fn(self) "debug"}
        \\ const value = set_meta({}, mt)
        \\ "value = #{value:?}"
    , "value = \"debug\"");
    try t.topString(
        \\ "100% complete: #{42:p}"
    , "100% complete: \x1b[33m42\x1b[0m");
}

test "metamethod __index for field access" {
    try t.topNumber(
        \\ const mt = {__index = fn(self, key) 42}
        \\ const t = set_meta({}, mt)
        \\ t.missing_field
    , 42);
}

test "plain metatable fields resolve before __index" {
    try t.topNumber(
        \\ const mt = {value = 7, __index = fn(self, key) 99}
        \\ const t = set_meta({}, mt)
        \\ t.value
    , 7);
}

test "metamethod failures are runtime errors not host panics" {
    try t.expectRuntimeFailureWithMessage(
        \\ const mt = {__tostring = fn(self) panic("boom")}
        \\ const t = set_meta({}, mt)
        \\ string(t)
    , .Panic, "boom");
}

test "errs returned at toplevel report proper span" {
    try t.expectRuntimeFailure(
        \\ do
        \\ {:err, "boom"}?
        \\ end
    , .Panic, 2, 2, "\x1b[32m\"boom\"\x1b[0m");
}

test "if-let works" {
    try t.topNumber(
        \\ let t = {count = 100}
        \\ 
        \\ if not (let cnt = t.count)
        \\   return :false
        \\ 
        \\ expect_eq(cnt, 100)
        \\ 
        \\ let acc = 0
        \\ 
        \\ for i in 0..cnt do
        \\   acc += 1
        \\ end
        \\ 
        \\ acc
    , 100);
}

test "metamethod __newindex for field assignment" {
    try t.topNumber(
        \\ const mt = {__newindex = fn(self, key, value) table.rawset(self, key, 99)}
        \\ const t = set_meta({}, mt)
        \\ t.x = 5
        \\ t.x
    , 99); // todo assert!(99 == t.x = 5)
}

test "method calls require obj:method(args)" {
    try t.topNumber(
        \\ const mt = {get_x = fn(self) self.x}
        \\ const t = set_meta({x = 12}, mt)
        \\ t:get_x()
    , 12);
    try t.topNumber(
        \\ const Email = {parse = fn(x) x}
        \\ Email.parse(42)
    , 42);
}

test "metatable-backed constructor and instance methods compile" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const source =
        \\ let DB = set_meta({}, {
        \\     open = fn(self) print("opened"),
        \\     close = fn(self) print("closed"),
        \\     new = fn(self, filename) do self["filename"] = filename end
        \\ })
        \\ 
        \\ let first_db = DB:new("./first.db")
        \\ let second_db = DB:new("./second.db")
        \\ 
        \\ first_db:open()
        \\ second_db:open()
        \\ second_db:close()
        \\ first_db:close()
    ;

    const built = try lang.build(&vm, .{ .text = source }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
    try std.testing.expect(built.ok.instructions.len != 0);
}

test "plain field access returns the raw resolved value" {
    try t.topType(
        \\ const mt = {id = fn(self) self}
        \\ const t = set_meta({}, mt)
        \\ t.id
    , .function);
}

test "non-table values can use plain metatable fields as methods" {
    try t.topString(
        \\ const mt = {reverse = fn(self) "fdsa"}
        \\ set_meta("", mt)
        \\ "asdf":reverse()
    , "fdsa");
}

//
// error vals
//

test "error helpers build and classify tagged errors" {
    try t.topString("string({:ok, 42})", "{ :ok, 42 }");
    try t.topString("string({:err, :FileNotFound})", "{ :err, :FileNotFound }");
}

test "unwrap panics on err result" {
    try t.expectRuntimeFailureWithMessage(
        \\ {:err, :Unlucky}:unwrap()
    , .Panic, ":Unlucky");
}

test "unwrap rejects non-results at runtime" {
    try t.expectRuntimeError(
        \\ {1, 2}:unwrap()
    , .TypeError);
}
