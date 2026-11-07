const mvzr = @import("vendor/mvzr.zig");

const revo = @import("../root.zig");
const Value = revo.Value;
const VM = revo.VM;
const root = @import("root.zig");
const HostResult = root.host.HostResult;

const Args = root.host.ArgTypes;

pub const Impl = struct {
    pub fn __call(vm: *VM, self: Args.any, pattern: Args.string) !HostResult {
        _ = self;
        return compile(vm, pattern);
    }
    pub fn compile(vm: *VM, pattern: Args.string) !HostResult {
        const pattern_str = try vm.runtime.alloc.dupe(u8, vm.stringValue(@backingInt(pattern)));
        defer vm.runtime.alloc.free(pattern_str);

        const regex = try vm.runtime.alloc.create(mvzr.Regex);
        errdefer vm.runtime.alloc.destroy(regex);
        regex.* = mvzr.compile(pattern_str) orelse {
            vm.runtime.alloc.destroy(regex);
            return .data(Value.new.nil());
        };

        const tid = try vm.tables.create();
        try vm.putField(tid, "_ptr", Value.new.@"opaque"(@ptrCast(regex)));
        try vm.putField(tid, "_pattern", Value.new.str(@backingInt(pattern)));

        const gc_fn_id = try vm.installHost("__regex_gc", .{
            .arity = 1,
            .param_types = &.{.table},
            .func = gcFn,
            .variadic = false,
            .ret_type = .any,
        });

        try vm.registerFinalizer(tid, Value.new.function(gc_fn_id));

        return .data(Value.new.table(tid));
    }

    pub fn is_match(vm: *VM, val: Args.any, haystack: Args.string) !HostResult {
        const r = resolveRegex(val, vm) catch return ._bool(false);
        const owned = r.owned;
        defer if (owned) vm.runtime.alloc.destroy(r.regex);
        const hay = vm.stringValue(@backingInt(haystack));
        return ._bool(r.regex.isMatch(hay));
    }

    pub fn find(vm: *VM, val: Args.any, haystack: Args.string) !HostResult {
        const r = resolveRegex(val, vm) catch return .data(Value.new.nil());
        const owned = r.owned;
        defer if (owned) vm.runtime.alloc.destroy(r.regex);
        const hay = vm.stringValue(@backingInt(haystack));
        if (r.regex.match(hay)) |m| {
            return .data(try vm.ownValueString(m.slice));
        }
        return .data(Value.new.nil());
    }

    pub fn find_all(vm: *VM, val: Args.any, haystack: Args.string) !HostResult {
        const r = resolveRegex(val, vm) catch return .data(Value.new.nil());

        const it_id = try vm.tables.create();

        try vm.putField(it_id, "_ptr", Value.new.@"opaque"(@ptrCast(r.regex)));
        try vm.putField(it_id, "haystack", Value.new.str(@backingInt(haystack)));
        try vm.putField(it_id, "pos", Value.new.num(0));

        if (r.owned) {
            const gc_fn_id = try vm.installHost("__regex_it_gc", .{
                .arity = 1,
                .param_types = &.{.table},
                .func = itGcFn,
                .variadic = false,
                .ret_type = .any,
            });
            try vm.registerFinalizer(it_id, Value.new.function(gc_fn_id));
        }

        const next_fn_id = try vm.installHost("__regex_next", .{
            .arity = 1,
            .param_types = &.{.table},
            .func = nextFn,
            .variadic = false,
            .ret_type = .any,
        });
        try vm.putField(it_id, "__call", Value.new.function(next_fn_id));

        return .data(Value.new.table(it_id));
    }

    pub fn free(vm: *VM, tbl: Args.table) !HostResult {
        const val = Value.new.table(@backingInt(tbl));
        const ptr_val = vm.getField(val, "_ptr") orelse
            return .data(Value.new.nil());
        const regex_ptr = ptr_val.asOpaque().?;
        const regex: *mvzr.Regex = @ptrCast(@alignCast(regex_ptr));

        _ = vm.removeField(val, "_ptr");
        vm.runtime.alloc.destroy(regex);
        vm.unregisterFinalizer(@backingInt(tbl));

        return .data(Value.new.nil());
    }
};

pub const impls = root.host.impls(Impl).val;

fn getRegexFromTable(val: Value, vm: *VM) !*mvzr.Regex {
    const ptr_val = vm.getField(val, "_ptr") orelse
        return error.InvalidRegex;
    const regex_ptr = ptr_val.asOpaque().?;
    return @ptrCast(@alignCast(regex_ptr));
}

fn compileFromString(str_val: Value, vm: *VM) !*mvzr.Regex {
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

fn resolveRegex(val: Value, vm: *VM) !ResolvedRegex {
    if (val.isTable()) {
        return .{ .regex = try getRegexFromTable(val, vm), .owned = false };
    }
    if (val.isString()) {
        return .{ .regex = try compileFromString(val, vm), .owned = true };
    }
    return error.InvalidRegex;
}

fn itGcFn(args: []const Value, vm: *VM) !HostResult {
    const ptr_val = vm.getField(args[0], "_ptr") orelse
        return .data(Value.new.nil());
    const regex_ptr = ptr_val.asOpaque().?;
    const regex: *mvzr.Regex = @ptrCast(@alignCast(regex_ptr));
    _ = vm.removeField(args[0], "_ptr");
    vm.runtime.alloc.destroy(regex);
    return .data(Value.new.nil());
}

fn gcFn(args: []const Value, vm: *VM) !HostResult {
    const ptr_val = vm.getField(args[0], "_ptr") orelse
        return .data(Value.new.nil());
    const regex_ptr = ptr_val.asOpaque().?;
    const regex: *mvzr.Regex = @ptrCast(@alignCast(regex_ptr));
    _ = vm.removeField(args[0], "_ptr");
    vm.runtime.alloc.destroy(regex);
    return .data(Value.new.nil());
}

fn nextFn(args: []const Value, vm: *VM) !HostResult {
    const tid = args[0].asTable().?;
    const table = try vm.tables.get(tid);

    const ptr_val = vm.getField(args[0], "_ptr") orelse
        return .data(Value.new.core(.done));
    const haystack_val = vm.getField(args[0], "haystack") orelse
        return .data(Value.new.core(.done));
    const pos_val = vm.getField(args[0], "pos") orelse
        return .data(Value.new.core(.done));

    const regex: *mvzr.Regex = @ptrCast(@alignCast(ptr_val.asOpaque().?));
    const haystack = vm.stringValue(haystack_val.asString().?);
    const pos: usize = root.host.numToInt(usize, pos_val.asNumOpt().?) orelse
        return .data(Value.new.core(.done));

    if (pos > haystack.len) return .data(Value.new.core(.done));

    const substack = haystack[pos..];
    if (regex.match(substack)) |m| {
        const next_pos = pos + @max(m.end, 1);
        try table.putRaw(Value.new.atom(revo.CoreAtoms.pos.atomId()), Value.new.num(next_pos), vm);

        const match_tid = try vm.tables.create();
        try vm.putField(match_tid, "start", Value.new.num(pos + m.start));
        try vm.putField(match_tid, "end", Value.new.num(pos + m.end));
        try vm.putField(match_tid, "match", try vm.ownValueString(m.slice));

        return .data(Value.new.table(match_tid));
    }

    return .data(Value.new.core(.done));
}
