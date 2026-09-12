const Ts = root.T;

pub const Impl = struct {
    pub fn len(vm: *VM, self: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        return .data(Data.new.num(str.len));
    }

    pub fn upper(vm: *VM, self: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const buf = try vm.runtime.alloc.dupe(u8, str);
        for (buf) |*c| c.* = std.ascii.toUpper(c.*);
        return .data(try vm.adoptDataStringNoDedup(buf));
    }

    pub fn lower(vm: *VM, self: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const buf = try vm.runtime.alloc.dupe(u8, str);
        for (buf) |*c| c.* = std.ascii.toLower(c.*);
        return .data(try vm.adoptDataStringNoDedup(buf));
    }

    pub fn sub(vm: *VM, self: Ts.string, start: Ts.number, length: Ts.number) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const s = @as(i64, @intFromFloat(start));
        const l = @as(i64, @intFromFloat(length));
        if (s < 0 or l < 0 or s >= str.len) {
            return .data(try vm.ownDataString(""));
        }
        const end = @min(@as(usize, @intCast(s + l)), str.len);
        const s_u: usize = @intCast(s);
        return .data(try vm.ownDataStringNoDedup(str[s_u..end]));
    }

    pub fn find(vm: *VM, self: Ts.string, needle: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const ndl = vm.stringValue(@intFromEnum(needle));
        if (std.mem.find(u8, str, ndl)) |pos| {
            return .data(Data.new.num(pos));
        }
        return .data(revo.Data.new.core(.missing));
    }

    pub fn replace(vm: *VM, self: Ts.string, old: Ts.string, new: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const o = vm.stringValue(@intFromEnum(old));
        const n = vm.stringValue(@intFromEnum(new));
        const res = try std.mem.replaceOwned(u8, vm.runtime.alloc, str, o, n);
        return .data(try vm.adoptDataStringNoDedup(res));
    }

    pub fn split(vm: *VM, self: Ts.string, delim: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const d = vm.stringValue(@intFromEnum(delim));
        var parts = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 10);
        defer parts.deinit(vm.runtime.alloc);

        const collapse = d.len == 1 and d[0] == ' ';
        var pos: usize = 0;
        while (std.mem.find(u8, str[pos..], d)) |idx| {
            const abs_idx = pos + idx;
            const part = str[pos..abs_idx];
            if (!collapse or part.len > 0) {
                try parts.append(vm.runtime.alloc, try vm.ownDataStringNoDedup(part));
            }
            pos = abs_idx + d.len;
        }
        const final_part = str[pos..];
        if (!collapse or final_part.len > 0) {
            try parts.append(vm.runtime.alloc, try vm.ownDataStringNoDedup(final_part));
        }

        return .data(try vm.tableOfSlice(parts.items));
    }

    pub fn trim(vm: *VM, self: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        return .data(try vm.ownDataStringNoDedup(std.mem.trim(u8, str, " \t\r\n")));
    }

    pub fn reverse(vm: *VM, self: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const duped = try vm.runtime.alloc.dupe(u8, str);
        std.mem.reverse(u8, duped);
        return .data(try vm.adoptDataStringNoDedup(duped));
    }

    pub fn table(vm: *VM, self: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        var chars = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, str.len);
        defer chars.deinit(vm.runtime.alloc);
        for (str) |byte| {
            const char_str = try vm.adoptDataStringNoDedup(try vm.runtime.alloc.dupe(u8, &[_]u8{byte}));
            try chars.append(vm.runtime.alloc, char_str);
        }
        return .data(try vm.tableOfSlice(chars.items));
    }

    pub fn ascii(vm: *VM, self: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        if (str.len == 0) return .errType(0, "non-empty string", "empty string");
        return .data(Data.new.num(str[0]));
    }

    pub fn index_of(vm: *VM, self: Ts.string, search: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const s = vm.stringValue(@intFromEnum(search));
        if (std.mem.find(u8, str, s)) |idx| {
            return .data(Data.new.num(idx));
        }
        return .data(revo.Data.new.core(.nil));
    }

    pub fn of_ascii(vm: *VM, n: Ts.number) !HostResult {
        const code: u32 = root.numToInt(u32, n) orelse return .errType(0, "non-negative integer", "invalid integer");
        if (code > 127) return .other("ASCII code out of range");
        const char = try vm.runtime.alloc.dupe(u8, &[_]u8{@as(u8, @truncate(code))});
        return .data(try vm.adoptDataString(char));
    }

    pub fn join(vm: *VM, tbl: Ts.table, sep: Ts.string) !HostResult {
        const tbl_data = try vm.tables.get(@intFromEnum(tbl));
        const separator = vm.stringValue(@intFromEnum(sep));
        var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 64);
        defer buf.deinit(vm.runtime.alloc);
        for (tbl_data.array.items, 0..) |item, i| {
            const item_str = if (item.asString()) |sid|
                vm.stringValue(sid)
            else if (item.asNum()) |num| blk: {
                var fmt_buf: [64]u8 = undefined;
                break :blk std.fmt.bufPrint(&fmt_buf, "{}", .{num}) catch "?";
            } else "?";
            try buf.appendSlice(vm.runtime.alloc, item_str);
            if (i < tbl_data.array.items.len - 1) {
                try buf.appendSlice(vm.runtime.alloc, separator);
            }
        }
        return .data(try vm.adoptDataStringNoDedup(try buf.toOwnedSlice(vm.runtime.alloc)));
    }

    pub fn add(vm: *VM, self: Ts.string, other: Ts.string) !HostResult {
        const l_str = vm.stringValue(@intFromEnum(self));
        const r_str = vm.stringValue(@intFromEnum(other));
        if (l_str.len == 0) return .data(Data.new.str(@intFromEnum(other)));
        if (r_str.len == 0) return .data(Data.new.str(@intFromEnum(self)));
        const buf = try std.mem.concat(vm.runtime.alloc, u8, &.{ l_str, r_str });
        return .data(try vm.adoptDataStringNoDedup(buf));
    }

    pub fn repeat(vm: *VM, self: Ts.string, n: Ts.number) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const times: i64 = root.numToInt(i64, n) orelse return .errType(1, "integer num", "non-integer num");
        if (times < 0) return .errType(1, "non-negative num", "negative num");
        const count: usize = @intCast(times);
        if (count == 0) return .data(try vm.ownDataString(""));
        if (count == 1) return .data(Data.new.str(@intFromEnum(self)));
        const total_len = std.math.mul(usize, str.len, count) catch return .other("result too large");
        const buf = try vm.runtime.alloc.alloc(u8, total_len);
        for (0..count) |i| {
            @memcpy(buf[i * str.len ..][0..str.len], str);
        }
        return .data(try vm.adoptDataStringNoDedup(buf));
    }

    pub fn with(vm: *VM, self: Ts.string, idx: Ts.number, char_val: Ts.any) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const i: usize = try revo.asIndex(idx);
        if (i >= str.len) return .data(revo.Data.new.core(.missing));

        const char: u8 = blk: {
            if (char_val.asString()) |s| {
                const s_val = vm.stringValue(s);
                if (s_val.len == 0) return .errType(2, "non-empty string", root.typeof(char_val, vm));
                break :blk s_val[0];
            } else if (char_val.asNum()) |val| {
                if (!std.math.isFinite(val)) return .errType(2, "string or byte", root.typeof(char_val, vm));
                break :blk @intFromFloat(std.math.clamp(@round(val), 0, 255));
            } else {
                return .errType(2, "string or byte", root.typeof(char_val, vm));
            }
        };

        var new_buf = try vm.runtime.alloc.dupe(u8, str);
        errdefer vm.runtime.alloc.free(new_buf);
        new_buf[i] = char;
        return .data(try vm.adoptDataStringNoDedup(new_buf));
    }

    pub fn __call(vm: *VM, self: Ts.any, arg: Ts.any) !HostResult {
        _ = self;
        return root.string_(&.{arg}, vm);
    }

    pub fn @"contains?"(vm: *VM, self: Ts.string, arg: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const search = vm.stringValue(@intFromEnum(arg));
        return ._bool(std.mem.find(u8, str, search) != null);
    }
    pub fn @"starts_with?"(vm: *VM, self: Ts.string, prefix: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const pfx = vm.stringValue(@intFromEnum(prefix));
        return ._bool(std.mem.startsWith(u8, str, pfx));
    }
    pub fn @"ends_with?"(vm: *VM, self: Ts.string, suffix: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        const sfx = vm.stringValue(@intFromEnum(suffix));
        return ._bool(std.mem.endsWith(u8, str, sfx));
    }

    pub fn @"is_upper?"(vm: *VM, self: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        if (str.len == 0) return ._bool(false);
        for (str) |char| {
            if (!std.ascii.isUpper(char)) return ._bool(false);
        }
        return ._bool(true);
    }

    pub fn @"is_lower?"(vm: *VM, self: Ts.string) !HostResult {
        const str = vm.stringValue(@intFromEnum(self));
        if (str.len == 0) return ._bool(false);
        for (str) |char| {
            if (!std.ascii.isLower(char)) return ._bool(false);
        }
        return ._bool(true);
    }
};

pub const impls = root.impls(Impl).val;

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
    try testing.topTrue("\"HELLO\":is_upper?()");
    try testing.topFalse("\"Hello\":is_upper?()");
    try testing.topTrue("\"hello\":is_lower?()");
    try testing.topFalse("\"Hello\":is_lower?()");
    try testing.topFalse("\"hello\":contains?(\"xyz\")");
    try testing.topNumber("\"hello\":index_of(\"ll\")", 2);
    try testing.topString("string.of_ascii(97)", "a");
    try testing.topString("'hello':upper()", "HELLO");
    try testing.expectCompileError("'hello':sub('x', 2)", .ParseError);
    try testing.expectCompileError("'hello':sub(2, 2, 3)", .ParseError);
    try testing.topNumber("'hello':find('el')", 1);
    try testing.expectCompileError("'hello':find(42)", .ParseError);
    try testing.topString("'hello':replace('l', 'x')", "hexxo");
    try testing.expectCompileError("'hello':replace(1, 'x')", .ParseError);
    try testing.topString("'hello':add(' world')", "hello world");
    try testing.topString("\"\":add(\"abc\")", "abc");
    try testing.topString("\"abc\":add(\"\")", "abc");
    try testing.topString("\"ab\":repeat(3)", "ababab");
    try testing.topString("\"x\":repeat(1)", "x");
    try testing.topString("\"x\":repeat(0)", "");
    try testing.expectRuntimeFailureWithMessage(
        \\ "abc":with(1, "")
    , .TypeError, "arg 2: wants non-empty string, got string");
}

const std = @import("std");

const revo = @import("../root.zig");
const testing = revo.lang.testing;
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const HostResult = root.HostResult;
