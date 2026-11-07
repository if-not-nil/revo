const Args = root.host.ArgTypes;

pub const Impl = struct {
    pub fn len(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        return .data(Value.new.num(str.len));
    }

    pub fn upper(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const buf = try vm.runtime.alloc.dupe(u8, str);
        for (buf) |*c| c.* = std.ascii.toUpper(c.*);
        return .data(try vm.adoptValueStringNoDedup(buf));
    }

    pub fn lower(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const buf = try vm.runtime.alloc.dupe(u8, str);
        for (buf) |*c| c.* = std.ascii.toLower(c.*);
        return .data(try vm.adoptValueStringNoDedup(buf));
    }

    pub fn sub(vm: *VM, self: Args.string, start: Args.number, length: Args.number) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const s = @as(i64, @intFromFloat(start));
        const l = @as(i64, @intFromFloat(length));
        if (s < 0 or l < 0 or s >= str.len) {
            return .data(try vm.ownValueString(""));
        }
        const end = @min(@as(usize, @intCast(s + l)), str.len);
        const s_u: usize = @intCast(s);
        return .data(try vm.ownValueStringNoDedup(str[s_u..end]));
    }

    pub fn replace(vm: *VM, self: Args.string, old: Args.string, new: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const o = vm.stringValue(@backingInt(old));
        const n = vm.stringValue(@backingInt(new));
        const res = try std.mem.replaceOwned(u8, vm.runtime.alloc, str, o, n);
        return .data(try vm.adoptValueStringNoDedup(res));
    }

    pub fn split(vm: *VM, self: Args.string, delim: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const d = vm.stringValue(@backingInt(delim));
        var parts = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, 10);
        defer parts.deinit(vm.runtime.alloc);

        const collapse = d.len == 1 and d[0] == ' ';
        var pos: usize = 0;
        while (std.mem.find(u8, str[pos..], d)) |idx| {
            const abs_idx = pos + idx;
            const part = str[pos..abs_idx];
            if (!collapse or part.len > 0) {
                try parts.append(vm.runtime.alloc, try vm.ownValueStringNoDedup(part));
            }
            pos = abs_idx + d.len;
        }
        const final_part = str[pos..];
        if (!collapse or final_part.len > 0) {
            try parts.append(vm.runtime.alloc, try vm.ownValueStringNoDedup(final_part));
        }

        return .data(try vm.tableOfSlice(parts.items));
    }

    pub fn trim(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        return .data(try vm.ownValueStringNoDedup(std.mem.trim(u8, str, " \t\r\n")));
    }

    pub fn reverse(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const duped = try vm.runtime.alloc.dupe(u8, str);
        std.mem.reverse(u8, duped);
        return .data(try vm.adoptValueStringNoDedup(duped));
    }

    pub fn table(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        var chars = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, str.len);
        defer chars.deinit(vm.runtime.alloc);
        for (str) |byte| {
            const char_str = try vm.adoptValueStringNoDedup(try vm.runtime.alloc.dupe(u8, &[_]u8{byte}));
            try chars.append(vm.runtime.alloc, char_str);
        }
        return .data(try vm.tableOfSlice(chars.items));
    }

    pub fn ascii(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        if (str.len == 0) return .errType(0, "non-empty string", "empty string");
        return .data(Value.new.num(str[0]));
    }

    pub fn index_of(vm: *VM, self: Args.string, search: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const s = vm.stringValue(@backingInt(search));
        if (std.mem.find(u8, str, s)) |idx| {
            return .data(Value.new.num(idx));
        }
        return .data(revo.Value.new.core(.nil));
    }

    pub fn of_ascii(vm: *VM, n: Args.number) !HostResult {
        const code: u32 = root.host.numToInt(u32, n) orelse return .errType(0, "non-negative integer", "invalid integer");
        if (code > 127) return .other("ASCII code out of range");
        const char = try vm.runtime.alloc.dupe(u8, &[_]u8{@as(u8, @truncate(code))});
        return .data(try vm.adoptValueString(char));
    }

    pub fn join(vm: *VM, tbl: Args.table, sep: Args.string) !HostResult {
        const tbl_data = try vm.tables.get(@backingInt(tbl));
        const separator = vm.stringValue(@backingInt(sep));
        var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 64);
        defer buf.deinit(vm.runtime.alloc);
        for (tbl_data.array.items, 0..) |item, i| {
            const item_str = if (item.asString()) |sid|
                vm.stringValue(sid)
            else if (item.asNumOpt()) |num| blk: {
                var fmt_buf: [64]u8 = undefined;
                break :blk std.mem.print(&fmt_buf, "{}", .{num}) catch "?";
            } else "?";
            try buf.appendSlice(vm.runtime.alloc, item_str);
            if (i < tbl_data.array.items.len - 1) {
                try buf.appendSlice(vm.runtime.alloc, separator);
            }
        }
        return .data(try vm.adoptValueStringNoDedup(try buf.toOwnedSlice(vm.runtime.alloc)));
    }

    pub fn concat(vm: *VM, self: Args.string, other: Args.string) !HostResult {
        const l_str = vm.stringValue(@backingInt(self));
        const r_str = vm.stringValue(@backingInt(other));
        if (l_str.len == 0) return .data(Value.new.str(@backingInt(other)));
        if (r_str.len == 0) return .data(Value.new.str(@backingInt(self)));
        const buf = try std.mem.concat(vm.runtime.alloc, u8, &.{ l_str, r_str });
        return .data(try vm.adoptValueStringNoDedup(buf));
    }

    pub fn repeat(vm: *VM, self: Args.string, n: Args.number) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const times: i64 = root.host.numToInt(i64, n) orelse return .errType(1, "integer number", "non-integer numberber");
        if (times < 0) return .errType(1, "non-negative numberber", "negative number");
        const count: usize = @intCast(times);
        if (count == 0) return .data(try vm.ownValueString(""));
        if (count == 1) return .data(Value.new.str(@backingInt(self)));
        const total_len = std.math.mul(usize, str.len, count) catch return .other("result too large");
        const buf = try vm.runtime.alloc.alloc(u8, total_len);
        for (0..count) |i| {
            @memcpy(buf[i * str.len ..][0..str.len], str);
        }
        return .data(try vm.adoptValueStringNoDedup(buf));
    }

    pub fn with(vm: *VM, self: Args.string, idx: Args.number, char_val: Args.any) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const i: usize = try revo.asIndex(idx);
        if (i >= str.len) return .data(revo.Value.new.core(.missing));

        const char: u8 = blk: {
            if (char_val.asString()) |s| {
                const s_val = vm.stringValue(s);
                if (s_val.len == 0) return .errType(2, "non-empty string", root.typeof(char_val, vm));
                break :blk s_val[0];
            } else if (char_val.asNumOpt()) |val| {
                if (!std.math.isFinite(val)) return .errType(2, "string or byte", root.typeof(char_val, vm));
                break :blk @intFromFloat(std.math.clamp(@round(val), 0, 255));
            } else {
                return .errType(2, "string or byte", root.typeof(char_val, vm));
            }
        };

        var new_buf = try vm.runtime.alloc.dupe(u8, str);
        errdefer vm.runtime.alloc.free(new_buf);
        new_buf[i] = char;
        return .data(try vm.adoptValueStringNoDedup(new_buf));
    }

    pub fn __call(vm: *VM, self: Args.any, arg: Args.any) !HostResult {
        _ = self;
        return root.string_(&.{arg}, vm);
    }

    pub fn @"contains?"(vm: *VM, self: Args.string, arg: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const search = vm.stringValue(@backingInt(arg));
        return ._bool(std.mem.find(u8, str, search) != null);
    }
    pub fn @"starts_with?"(vm: *VM, self: Args.string, prefix: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const pfx = vm.stringValue(@backingInt(prefix));
        return ._bool(std.mem.startsWith(u8, str, pfx));
    }
    pub fn @"ends_with?"(vm: *VM, self: Args.string, suffix: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        const sfx = vm.stringValue(@backingInt(suffix));
        return ._bool(std.mem.endsWith(u8, str, sfx));
    }

    pub fn @"upper?"(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        if (str.len == 0) return ._bool(false);
        for (str) |char| {
            if (!std.ascii.isUpper(char)) return ._bool(false);
        }
        return ._bool(true);
    }

    pub fn @"lower?"(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        if (str.len == 0) return ._bool(false);
        for (str) |char| {
            if (!std.ascii.isLower(char)) return ._bool(false);
        }
        return ._bool(true);
    }

    pub fn @"alnum?"(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        if (str.len == 0) return ._bool(false);
        for (str) |char| {
            if (!std.ascii.isAlphanumeric(char)) return ._bool(false);
        }
        return ._bool(true);
    }

    pub fn @"alpha?"(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        if (str.len == 0) return ._bool(false);
        for (str) |char| {
            if (!std.ascii.isAlphabetic(char)) return ._bool(false);
        }
        return ._bool(true);
    }

    pub fn @"whitespace?"(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        if (str.len == 0) return ._bool(false);
        for (str) |char| {
            if (!std.ascii.isWhitespace(char)) return ._bool(false);
        }
        return ._bool(true);
    }

    pub fn @"punct?"(vm: *VM, self: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(self));
        if (str.len == 0) return ._bool(false);
        for (str) |char| {
            if (!std.ascii.isPunctuation(char)) return ._bool(false);
        }
        return ._bool(true);
    }
};

pub const impls = root.host.impls(Impl).val;

test "string metatable" {
    try testing.topString("\"hello\":sub(0, 2)", "he");

    try testing.topNumber("len(\"asdf\")", 4);
    try testing.topNumber("\"asdf\":len()", 4);
    try testing.topString("\"asdf\":with(1, \"y\")", "aydf");
    try testing.topString("string(\"asdf\")", "asdf");
    try testing.topString("\"asdf\"[2]", "d");
    try testing.topString("\"asdf\" ~ \"qwer\"", "asdfqwer");
}

test "string methods" {
    try testing.topTrue("\"hello\":contains?(\"ell\")");
    try testing.topFalse("\"hello\":contains?(\"xyz\")");
    try testing.topTrue("\"HELLO\":upper?()");
    try testing.topFalse("\"Hello\":upper?()");
    try testing.topTrue("\"hello\":lower?()");
    try testing.topFalse("\"Hello\":lower?()");
    try testing.topFalse("\"hello\":contains?(\"xyz\")");
    try testing.topNumber("\"hello\":index_of(\"ll\")", 2);
    try testing.topString("string.of_ascii(97)", "a");
    try testing.topString("'hello':upper()", "HELLO");
    try testing.expectSemanticError("'hello':sub('x', 2)");
    try testing.expectSemanticError("'hello':sub(2, 2, 3)");
    try testing.topNumber("'hello':index_of('el')", 1);
    try testing.expectSemanticError("'hello':index_of(42)");
    try testing.topString("'hello':replace('l', 'x')", "hexxo");
    try testing.expectSemanticError("'hello':replace(1, 'x')");
    try testing.topString("'hello':concat(' world')", "hello world");
    try testing.topString("\"\":concat(\"abc\")", "abc");
    try testing.topString("\"abc\":concat(\"\")", "abc");
    try testing.topString("\"ab\":repeat(3)", "ababab");
    try testing.topString("\"x\":repeat(1)", "x");
    try testing.topString("\"x\":repeat(0)", "");
    try testing.expectRuntimeFailureWithMessage(
        \\ "abc":with(1, "")
    , .TypeError, "arg 2: wants non-empty string, got string");
}

const std = @import("std");

const revo = @import("../root.zig");
const testing = revo.lang.test_helpers;
const Value = revo.Value;
const VM = revo.VM;
const root = @import("root.zig");
const HostResult = root.host.HostResult;
