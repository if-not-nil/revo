const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;

fn expectParseError(source: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const parsed = try lang.parse(arena.allocator(), .{ .text = source }, .{});
    switch (parsed) {
        .ok => return error.ExpectedParseFailure,
        .err => |failure| {
            for (failure.report.parts) |part| {
                if (part == .@"error" and std.mem.find(u8, part.@"error", needle) != null) return;
            }
            return error.ExpectedParseMessage;
        },
    }
}

test "bare calls take exactly one argument" {
    try expectParseError(
        \\ fn f(a) a
        \\ f "x" "y"
    , "bare calls take exactly one argument");
}

test "bare calls cannot chain off a call result" {
    try expectParseError(
        \\ fn g() fn(x) x
        \\ g() "x"
    , "a bare call cannot follow a call result");
}

test "colon calls need parens around a bare argument" {
    try expectParseError(
        \\ const o = {m = fn(self, x) x}
        \\ o:m "x"
    , "method calls need parentheses");
}

test "generic calls need parens around a bare argument" {
    try expectParseError(
        \\ fn id<T>(x) x
        \\ id<number> "x"
    , "generic calls need parentheses");
}

test "parser treats semicolons as whitespace characters" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const source =
        \\ const langs = {
        \\   "C", "C++",
        \\   "Java", "C#",
        \\   "Perl", "PHP",
        \\ };
        \\ fn fellow_heart_attacker(lang) do
        \\   "An old {lang} programmer won't have a heart attack " ~
        \\   "over a habitually placed closing semicolon.";
        \\ end
        \\ for lang in langs do
        \\   const statement = fellow_heart_attacker(lang);
        \\   print(statement);
        \\ end
    ;
    const parsed = try lang.parse(arena.allocator(), .{ .text = source }, .{});
    try std.testing.expect(parsed == .ok);
}

test "parser reports multiple syntax errors in one pass" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const source =
        \\ let x = )
        \\ let y = )
    ;
    const built = try lang.build(&vm, .{ .text = source }, .{});
    try std.testing.expect(built == .err);
    switch (built.err) {
        .parse => |failure| {
            var error_count: usize = 0;
            for (failure.report.parts) |part| {
                if (part == .@"error") error_count += 1;
            }
            try std.testing.expect(error_count >= 2);

            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try lang.renderError(&buf.writer, .{ .text = source }, .{ .parse = failure }, .{});
            try std.testing.expect(buf.written().len != 0);
        },
        else => return error.ExpectedCompileFailure,
    }
}
