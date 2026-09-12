const mvzr = @import("mvzr");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const HostResult = root.HostResult;

const Ts = root.T;

pub const Impl = struct {
    pub fn compile(vm: *VM, pattern: Ts.string) !HostResult {
        const pattern_str = try vm.runtime.alloc.dupe(u8, vm.stringValue(@intFromEnum(pattern)));
        defer vm.runtime.alloc.free(pattern_str);

        const regex = try vm.runtime.alloc.create(mvzr.Regex);
        errdefer vm.runtime.alloc.destroy(regex);
        regex.* = mvzr.compile(pattern_str) orelse {
            vm.runtime.alloc.destroy(regex);
            return .data(Data.new.nil());
        };

        const tid = try vm.tables.create();
        try vm.putField(tid, "_ptr", Data.new.foreign(@ptrCast(regex)));
        try vm.putField(tid, "_pattern", Data.new.str(@intFromEnum(pattern)));

        const gc_fn_id = try vm.installHost("__regex_gc", .{
            .arity = 1,
            .param_types = &.{.table},
            .func = gcFn,
            .variadic = false,
            .ret_type = .any,
        });

        try vm.registerFinalizer(tid, Data.new.function(gc_fn_id));

        return .data(Data.new.table(tid));
    }

    pub fn is_match(vm: *VM, val: Ts.any, haystack: Ts.string) !HostResult {
        const r = resolveRegex(val, vm) catch return ._bool(false);
        const owned = r.owned;
        defer if (owned) vm.runtime.alloc.destroy(r.regex);
        const hay = vm.stringValue(@intFromEnum(haystack));
        return ._bool(r.regex.isMatch(hay));
    }

    pub fn find(vm: *VM, val: Ts.any, haystack: Ts.string) !HostResult {
        const r = resolveRegex(val, vm) catch return .data(Data.new.nil());
        const owned = r.owned;
        defer if (owned) vm.runtime.alloc.destroy(r.regex);
        const hay = vm.stringValue(@intFromEnum(haystack));
        if (r.regex.match(hay)) |m| {
            return .data(try vm.ownDataString(m.slice));
        }
        return .data(Data.new.nil());
    }

    pub fn find_all(vm: *VM, val: Ts.any, haystack: Ts.string) !HostResult {
        const r = resolveRegex(val, vm) catch return .data(Data.new.nil());

        const it_id = try vm.tables.create();

        try vm.putField(it_id, "_ptr", Data.new.foreign(@ptrCast(r.regex)));
        try vm.putField(it_id, "haystack", Data.new.str(@intFromEnum(haystack)));
        try vm.putField(it_id, "pos", Data.new.num(0));

        if (r.owned) {
            const gc_fn_id = try vm.installHost("__regex_it_gc", .{
                .arity = 1,
                .param_types = &.{.table},
                .func = itGcFn,
                .variadic = false,
                .ret_type = .any,
            });
            try vm.registerFinalizer(it_id, Data.new.function(gc_fn_id));
        }

        const next_fn_id = try vm.installHost("__regex_next", .{
            .arity = 1,
            .param_types = &.{.table},
            .func = nextFn,
            .variadic = false,
            .ret_type = .any,
        });
        try vm.putField(it_id, "__call", Data.new.function(next_fn_id));

        return .data(Data.new.table(it_id));
    }

    pub fn free(vm: *VM, tbl: Ts.table) !HostResult {
        const val = Data.new.table(@intFromEnum(tbl));
        const ptr_val = vm.getField(val, "_ptr") orelse
            return .data(Data.new.nil());
        const regex_ptr = ptr_val.asForeign().?;
        const regex: *mvzr.Regex = @ptrCast(@alignCast(regex_ptr));

        _ = vm.removeField(val, "_ptr");
        vm.runtime.alloc.destroy(regex);
        vm.unregisterFinalizer(@intFromEnum(tbl));

        return .data(Data.new.nil());
    }
};

pub const impls = root.impls(Impl).val;

fn getRegexFromTable(val: Data, vm: *VM) !*mvzr.Regex {
    const ptr_val = vm.getField(val, "_ptr") orelse
        return error.InvalidRegex;
    const regex_ptr = ptr_val.asForeign().?;
    return @ptrCast(@alignCast(regex_ptr));
}

fn compileFromString(str_val: Data, vm: *VM) !*mvzr.Regex {
    const pattern = try vm.runtime.alloc.dupe(u8, vm.stringValue(str_val.asString().?));
    defer vm.runtime.alloc.free(pattern);
    const regex = try vm.runtime.alloc.create(mvzr.Regex);
    errdefer vm.runtime.alloc.destroy(regex);
    regex.* = mvzr.compile(pattern) orelse return error.CompileFailed;
    return regex;
}

const ResolvedRegex = struct {
    regex: *mvzr.Regex,
    owned: bool,
};

fn resolveRegex(val: Data, vm: *VM) !ResolvedRegex {
    if (val.isTable()) {
        return .{ .regex = try getRegexFromTable(val, vm), .owned = false };
    }
    if (val.isString()) {
        return .{ .regex = try compileFromString(val, vm), .owned = true };
    }
    return error.InvalidRegex;
}

fn itGcFn(args: []const Data, vm: *VM) !HostResult {
    const ptr_val = vm.getField(args[0], "_ptr") orelse
        return .data(Data.new.nil());
    const regex_ptr = ptr_val.asForeign().?;
    const regex: *mvzr.Regex = @ptrCast(@alignCast(regex_ptr));
    _ = vm.removeField(args[0], "_ptr");
    vm.runtime.alloc.destroy(regex);
    return .data(Data.new.nil());
}

fn gcFn(args: []const Data, vm: *VM) !HostResult {
    const ptr_val = vm.getField(args[0], "_ptr") orelse
        return .data(Data.new.nil());
    const regex_ptr = ptr_val.asForeign().?;
    const regex: *mvzr.Regex = @ptrCast(@alignCast(regex_ptr));
    _ = vm.removeField(args[0], "_ptr");
    vm.runtime.alloc.destroy(regex);
    return .data(Data.new.nil());
}

fn nextFn(args: []const Data, vm: *VM) !HostResult {
    const tid = args[0].asTable().?;
    const table = try vm.tables.get(tid);

    const ptr_val = vm.getField(args[0], "_ptr") orelse
        return .data(Data.new.core(.done));
    const haystack_val = vm.getField(args[0], "haystack") orelse
        return .data(Data.new.core(.done));
    const pos_val = vm.getField(args[0], "pos") orelse
        return .data(Data.new.core(.done));

    const regex: *mvzr.Regex = @ptrCast(@alignCast(ptr_val.asForeign().?));
    const haystack = vm.stringValue(haystack_val.asString().?);
    const pos: usize = root.numToInt(usize, pos_val.asNum().?) orelse
        return .data(Data.new.core(.done));

    if (pos > haystack.len) return .data(Data.new.core(.done));

    const substack = haystack[pos..];
    if (regex.match(substack)) |m| {
        const next_pos = pos + @max(m.end, 1);
        try table.putRaw(Data.new.atom(revo.core_atoms.pos.atomId()), Data.new.num(next_pos), vm);

        const match_tid = try vm.tables.create();
        try vm.putField(match_tid, "start", Data.new.num(pos + m.start));
        try vm.putField(match_tid, "end", Data.new.num(pos + m.end));
        try vm.putField(match_tid, "match", try vm.ownDataString(m.slice));

        return .data(Data.new.table(match_tid));
    }

    return .data(Data.new.core(.done));
}
