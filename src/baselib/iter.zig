const Args = root.host.ArgTypes;

pub const Impl = struct {
    pub fn to_iter(vm: *VM, obj: Args.any) !HostResult {
        const w = (try wrapIterable(vm, obj)) orelse
            return .errType(0, "iterable", typeof(obj, vm));
        if (w.isString() or w.isTable())
            return makeSeqIterator(vm, w);
        return .data(w);
    }

    pub fn enumerate(vm: *VM, obj: Args.any) !HostResult {
        const up = (try wrapIterable(vm, obj)) orelse
            return .errType(0, "iterable", typeof(obj, vm));
        const it_id = try makeIterator(vm, .enumerate);
        try putState(vm, it_id, .up, up);
        return .data(Value.new.table(it_id));
    }

    pub fn collect(vm: *VM, obj: Args.any) !HostResult {
        const st_id = toState(vm, obj) catch
            return .errType(0, "iterable", typeof(obj, vm));
        const out_id = try vm.tables.create();
        var v: Value = undefined;
        var idx: Value = undefined;
        while (try pullStep(vm, st_id, &v, &idx))
            try (try vm.tables.get(out_id)).array.append(vm.runtime.alloc, v);
        return .data(Value.new.table(out_id));
    }

    pub fn collect_string(vm: *VM, obj: Args.any) !HostResult {
        const st_id = toState(vm, obj) catch
            return .errType(0, "iterable", typeof(obj, vm));
        var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 0);
        defer buf.deinit(vm.runtime.alloc);
        var v: Value = undefined;
        var idx: Value = undefined;
        while (try pullStep(vm, st_id, &v, &idx)) {
            if (v.asString()) |s| {
                try buf.appendSlice(vm.runtime.alloc, vm.stringValue(s));
            } else if (v.asNumOpt()) |n| {
                try buf.append(vm.runtime.alloc, @as(u8, @intFromFloat(std.math.clamp(@round(n), 0, 255))));
            } else {
                return .errType(0, "string or number", typeof(v, vm));
            }
        }
        return .data(try vm.adoptValueString(try buf.toOwnedSlice(vm.runtime.alloc)));
    }

    pub fn each(vm: *VM, obj: Args.any, f: Args.function) !HostResult {
        const st_id = toState(vm, obj) catch
            return .errType(0, "iterable", typeof(obj, vm));
        var v: Value = undefined;
        var idx: Value = undefined;
        while (try pullStep(vm, st_id, &v, &idx))
            _ = try callPred(vm, Value.new.function(@backingInt(f)), v, idx);
        return HostResult.coreAtom(.ok);
    }

    pub fn find(vm: *VM, obj: Args.any, f: Args.function) !HostResult {
        const st_id = toState(vm, obj) catch
            return .errType(0, "iterable", typeof(obj, vm));
        var v: Value = undefined;
        var idx: Value = undefined;
        while (try pullStep(vm, st_id, &v, &idx)) {
            if (isTruthy(try callPred(vm, Value.new.function(@backingInt(f)), v, idx))) return .data(v);
        }
        return .data(revo.Value.new.core(.nil));
    }

    pub fn @"all?"(vm: *VM, obj: Args.any, f: Args.function) !HostResult {
        const st_id = toState(vm, obj) catch
            return .errType(0, "iterable", typeof(obj, vm));
        var v: Value = undefined;
        var idx: Value = undefined;
        while (try pullStep(vm, st_id, &v, &idx)) {
            if (!isTruthy(try callPred(vm, Value.new.function(@backingInt(f)), v, idx))) return ._bool(false);
        }
        return ._bool(true);
    }

    pub fn @"any?"(vm: *VM, obj: Args.any, f: Args.function) !HostResult {
        const st_id = toState(vm, obj) catch
            return .errType(0, "iterable", typeof(obj, vm));
        var v: Value = undefined;
        var idx: Value = undefined;
        while (try pullStep(vm, st_id, &v, &idx)) {
            if (isTruthy(try callPred(vm, Value.new.function(@backingInt(f)), v, idx))) return ._bool(true);
        }
        return ._bool(false);
    }

    pub fn reduce(vm: *VM, obj: Args.any, f: Args.function, init: Args.any) !HostResult {
        const st_id = toState(vm, obj) catch
            return .errType(0, "iterable", typeof(obj, vm));
        var acc = init;
        var v: Value = undefined;
        var idx: Value = undefined;
        while (try pullStep(vm, st_id, &v, &idx))
            acc = try vm.callFunctionParts(Value.new.function(@backingInt(f)), null, &[_]Value{ acc, v }, null);
        return .data(acc);
    }

    pub fn fold(vm: *VM, obj: Args.any, f: Args.function) !HostResult {
        const st_id = toState(vm, obj) catch
            return .errType(0, "iterable", typeof(obj, vm));
        var acc: Value = undefined;
        var got: bool = false;
        var v: Value = undefined;
        var idx: Value = undefined;
        while (try pullStep(vm, st_id, &v, &idx)) {
            if (!got) {
                acc = v;
                got = true;
            } else {
                acc = try vm.callFunctionParts(Value.new.function(@backingInt(f)), null, &[_]Value{ acc, v }, null);
            }
        }
        if (!got) return .data(revo.Value.new.core(.nil));
        return .data(acc);
    }

    pub fn sum(vm: *VM, obj: Args.any) !HostResult {
        const st_id = toState(vm, obj) catch
            return .errType(0, "iterable", typeof(obj, vm));
        var total: f64 = 0;
        var v: Value = undefined;
        var idx: Value = undefined;
        while (try pullStep(vm, st_id, &v, &idx)) {
            if (v.asNumOpt()) |n| total += n;
        }
        return .data(Value.new.num(total));
    }
};

pub const impls: []const specs.Impl = root.host.impls(Impl).val ++ &[_]specs.Impl{
    .{ .name = "to_iter", .f = root.host.define(&.{.any}, to_iter_fn) },
    .{ .name = "range", .f = root.host.defineVariadic(&.{.any}, range_fn) },
    .{ .name = "map", .f = root.host.define(&.{ .any, .function }, transformFn(.map)) },
    .{ .name = "filter", .f = root.host.define(&.{ .any, .function }, transformFn(.filter)) },
    .{ .name = "take", .f = root.host.define(&.{ .any, .any }, boundedFn(.take)) },
    .{ .name = "drop", .f = root.host.define(&.{ .any, .any }, boundedFn(.drop)) },
    .{ .name = "zip", .f = root.host.defineVariadic(&.{.any}, zip_fn) },
    .{ .name = "chunk", .f = root.host.define(&.{ .any, .any }, boundedFn(.chunk)) },
    .{ .name = "flat_map", .f = root.host.define(&.{ .any, .function }, transformFn(.flat_map)) },
    .{ .name = "count", .f = root.host.defineVariadic(&.{.any}, count_fn) },
};

fn to_iter_fn(args: []const Value, vm: *VM) !HostResult {
    const w = (try wrapIterable(vm, args[0])) orelse
        return .errType(0, "iterable", typeof(args[0], vm));
    if (w.isString() or w.isTable())
        return makeSeqIterator(vm, w);
    return .data(w);
}

const Kind = enum(usize) {
    seq,
    map,
    filter,
    take,
    drop,
    enumerate,
    chunk,
    zip,
    flat_map,
    range,
};

pub fn range_fn(args: []const Value, vm: *VM) !HostResult {
    const start: f64 = if (args.len == 1) 0 else blk: {
        const n = args[0].asNumOpt() orelse return .errType(0, "number", typeof(args[0], vm));
        break :blk n;
    };
    const end: f64 = if (args.len == 1) blk: {
        const n = args[0].asNumOpt() orelse return .errType(0, "number", typeof(args[0], vm));
        break :blk n;
    } else blk: {
        const n = args[1].asNumOpt() orelse return .errType(1, "number", typeof(args[1], vm));
        break :blk n;
    };
    const step: f64 = if (args.len >= 3) blk: {
        const n = args[2].asNumOpt() orelse return .errType(2, "number", typeof(args[2], vm));
        break :blk n;
    } else 1;
    if (step == 0) return .errType(2, "non-zero step", "0");

    const it_id = try makeIterator(vm, .range);
    try putState(vm, it_id, .a, Value.new.num(start));
    try putState(vm, it_id, .b, Value.new.num(end));
    try putState(vm, it_id, .step, Value.new.num(step));
    return .data(Value.new.table(it_id));
}

fn transformFn(comptime kind: Kind) root.host.HostFn {
    return struct {
        fn f(args: []const Value, vm: *VM) anyerror!HostResult {
            const up = (try wrapIterable(vm, args[0])) orelse
                return .errType(0, "iterable", typeof(args[0], vm));
            const it_id = try makeIterator(vm, kind);
            try putState(vm, it_id, .up, up);
            try putState(vm, it_id, .func, args[1]);
            return .data(Value.new.table(it_id));
        }
    }.f;
}

fn boundedFn(comptime kind: Kind) root.host.HostFn {
    return struct {
        fn f(args: []const Value, vm: *VM) anyerror!HostResult {
            const up = (try wrapIterable(vm, args[0])) orelse
                return .errType(0, "iterable", typeof(args[0], vm));
            const n = args[1].asNumOpt() orelse return .errType(1, "number", typeof(args[1], vm));
            const it_id = try makeIterator(vm, kind);
            try putState(vm, it_id, .up, up);
            try putState(vm, it_id, .n, Value.new.num(n));
            return .data(Value.new.table(it_id));
        }
    }.f;
}

pub fn zip_fn(args: []const Value, vm: *VM) !HostResult {
    if (args.len < 2) return .errArity(args.len, 2);
    var ups = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, args.len);
    defer ups.deinit(vm.runtime.alloc);
    for (args) |a| {
        const w = (try toCallable(vm, a)) orelse
            return .errType(0, "iterable", typeof(a, vm));
        try ups.append(vm.runtime.alloc, w);
    }
    const up_table = try vm.tableOfSlice(ups.items);
    const it_id = try makeIterator(vm, .zip);
    try putState(vm, it_id, .up, up_table);
    return .data(Value.new.table(it_id));
}

pub fn count_fn(args: []const Value, vm: *VM) !HostResult {
    if (args.len < 1 or args.len > 2) return .errArity(args.len, 1);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var n: f64 = 0;
    var v: Value = undefined;
    var idx: Value = undefined;
    while (try pullStep(vm, st_id, &v, &idx)) {
        if (args.len == 2 and !isTruthy(try callPred(vm, args[1], v, idx))) continue;
        n += 1;
    }
    return .data(Value.new.num(n));
}

fn iteratorNext(args: []const Value, vm: *VM) !HostResult {
    const table_id = args[0].asTable() orelse
        return .data(revo.Value.new.core(.done));
    const kind_val = (try vm.tables.get(table_id)).getRawAtom(revo.CoreAtoms.kind.atomId(), vm) orelse
        return .data(revo.Value.new.core(.done));
    const kind_num = kind_val.asNumOpt() orelse return .data(revo.Value.new.core(.done));
    const kind: Kind = @fromBackingInt(@intCast(@as(usize, @intFromFloat(kind_num))));
    return switch (kind) {
        .seq => seqNext(table_id, vm),
        .map => mapNext(table_id, vm),
        .filter => filterNext(table_id, vm),
        .take => takeNext(table_id, vm),
        .drop => dropNext(table_id, vm),
        .enumerate => enumerateNext(table_id, vm),
        .chunk => chunkNext(table_id, vm),
        .zip => zipNext(table_id, vm),
        .flat_map => flatMapNext(table_id, vm),
        .range => rangeNext(table_id, vm),
    };
}

fn seqNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var v: Value = undefined;
    var idx: Value = undefined;
    if (!try pullStep(vm, st_id, &v, &idx)) return .data(revo.Value.new.core(.done));
    return .data(v);
}

fn mapNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var v: Value = undefined;
    var idx: Value = undefined;
    if (!try pullStep(vm, st_id, &v, &idx)) return .data(revo.Value.new.core(.done));
    const f = (try vm.tables.get(st_id)).getRawAtom(revo.CoreAtoms.func.atomId(), vm) orelse
        return .data(revo.Value.new.core(.done));
    return .data(try callPred(vm, f, v, idx));
}

fn filterNext(st_id: mem.TableID, vm: *VM) !HostResult {
    const f = (try vm.tables.get(st_id)).getRawAtom(revo.CoreAtoms.func.atomId(), vm) orelse
        return .data(revo.Value.new.core(.done));
    while (true) {
        var v: Value = undefined;
        var idx: Value = undefined;
        if (!try pullStep(vm, st_id, &v, &idx)) return .data(revo.Value.new.core(.done));
        if (isTruthy(try callPred(vm, f, v, idx))) return .data(v);
    }
}

fn takeNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var st = try vm.tables.get(st_id);
    const n = (st.getRawAtom(revo.CoreAtoms.n.atomId(), vm) orelse Value.new.num(0)).asNumOpt().?;
    const taken = (st.getRawAtom(revo.CoreAtoms.count.atomId(), vm) orelse Value.new.num(0)).asNumOpt().?;
    if (taken >= n) return .data(revo.Value.new.core(.done));
    var v: Value = undefined;
    var idx: Value = undefined;
    if (!try pullStep(vm, st_id, &v, &idx)) return .data(revo.Value.new.core(.done));
    st = try vm.tables.get(st_id);
    try st.putRawAtom(revo.CoreAtoms.count.atomId(), Value.new.num(taken + 1), vm);
    return .data(v);
}

fn dropNext(st_id: mem.TableID, vm: *VM) !HostResult {
    while (true) {
        var v: Value = undefined;
        var idx: Value = undefined;
        if (!try pullStep(vm, st_id, &v, &idx)) return .data(revo.Value.new.core(.done));
        var st = try vm.tables.get(st_id);
        const n = (st.getRawAtom(revo.CoreAtoms.n.atomId(), vm) orelse Value.new.num(0)).asNumOpt().?;
        const dropped = (st.getRawAtom(revo.CoreAtoms.count.atomId(), vm) orelse Value.new.num(0)).asNumOpt().?;
        if (dropped >= n) return .data(v);
        try st.putRawAtom(revo.CoreAtoms.count.atomId(), Value.new.num(dropped + 1), vm);
    }
}

fn enumerateNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var v: Value = undefined;
    var idx: Value = undefined;
    if (!try pullStep(vm, st_id, &v, &idx)) return .data(revo.Value.new.core(.done));
    return .data(try vm.tableOfSlice(&[_]Value{ idx, v }));
}

fn chunkNext(st_id: mem.TableID, vm: *VM) !HostResult {
    const n_val = (try vm.tables.get(st_id)).getRawAtom(revo.CoreAtoms.n.atomId(), vm) orelse
        return .data(revo.Value.new.core(.done));
    const n = root.host.numToInt(usize, n_val.asNumOpt().?) orelse
        return .data(revo.Value.new.core(.done));
    const out_id = try vm.tables.create();
    var count: usize = 0;
    while (count < n) {
        var v: Value = undefined;
        var idx: Value = undefined;
        if (!try pullStep(vm, st_id, &v, &idx)) break;
        try (try vm.tables.get(out_id)).array.append(vm.runtime.alloc, v);
        count += 1;
    }
    if (count == 0) return .data(revo.Value.new.core(.done));
    return .data(Value.new.table(out_id));
}

fn zipNext(st_id: mem.TableID, vm: *VM) !HostResult {
    const ups_data = (try vm.tables.get(st_id)).getRawAtom(revo.CoreAtoms.up.atomId(), vm) orelse
        return .data(revo.Value.new.core(.done));
    const ups_id = ups_data.asTable() orelse return .data(revo.Value.new.core(.done));
    var vals = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, 0);
    defer vals.deinit(vm.runtime.alloc);
    var i: usize = 0;
    while (true) : (i += 1) {
        const ups = vm.tables.get(ups_id) catch return .data(revo.Value.new.core(.done));
        if (i >= ups.array.items.len) break;
        const v = try vm.callFunctionParts(ups.array.items[i], null, &.{}, null);
        if (isDone(v)) return .data(revo.Value.new.core(.done));
        try vals.append(vm.runtime.alloc, v);
    }
    return .data(try vm.tableOfSlice(vals.items));
}

fn flatMapNext(st_id: mem.TableID, vm: *VM) !HostResult {
    while (true) {
        var st = try vm.tables.get(st_id);
        const cur = st.getRawAtom(revo.CoreAtoms.cur.atomId(), vm) orelse revo.Value.new.core(.nil);
        if (cur.asAtom()) |a| {
            if (a == revo.CoreAtoms.atomId(.nil)) {
                var v: Value = undefined;
                var idx: Value = undefined;
                if (!try pullStep(vm, st_id, &v, &idx)) return .data(revo.Value.new.core(.done));
                const f = (try vm.tables.get(st_id)).getRawAtom(revo.CoreAtoms.func.atomId(), vm) orelse
                    return .data(revo.Value.new.core(.done));
                const mapped = try callPred(vm, f, v, idx);
                const sub = (try toCallable(vm, mapped)) orelse
                    return .errType(1, "iterable", typeof(mapped, vm));
                st = try vm.tables.get(st_id);
                try st.putRawAtom(revo.CoreAtoms.cur.atomId(), sub, vm);
                continue;
            }
        }
        const val = try vm.callFunctionParts(cur, null, &.{}, null);
        if (isDone(val)) {
            st = try vm.tables.get(st_id);
            try st.putRawAtom(revo.CoreAtoms.cur.atomId(), revo.Value.new.core(.nil), vm);
            continue;
        }
        return .data(val);
    }
}

fn rangeNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var st = try vm.tables.get(st_id);

    const a = (st.getRawAtom(revo.CoreAtoms.a.atomId(), vm) orelse Value.new.num(0)).asNumOpt().?;
    const b = (st.getRawAtom(revo.CoreAtoms.b.atomId(), vm) orelse Value.new.num(0)).asNumOpt().?;
    const step = (st.getRawAtom(revo.CoreAtoms.step.atomId(), vm) orelse Value.new.num(1)).asNumOpt().?;
    const cur = (st.getRawAtom(revo.CoreAtoms.pos.atomId(), vm) orelse Value.new.num(a)).asNumOpt().?;

    if ((step > 0 and cur >= b) or (step < 0 and cur <= b))
        return .data(revo.Value.new.core(.done));

    st = try vm.tables.get(st_id);
    try st.putRawAtom(revo.CoreAtoms.pos.atomId(), Value.new.num(cur + step), vm);

    return .data(Value.new.num(cur));
}

fn wrapIterable(vm: *VM, obj: Value) !?Value {
    if (obj.isFunction()) return obj;

    if (try vm.getMetamethodByAtom(obj, revo.CoreAtoms.__iter.atomId())) |mm|
        return try vm.callFunctionParts(mm, null, &[_]Value{obj}, null);

    if (obj.isTable() and try vm.resolveField(obj, Value.new.atom(revo.CoreAtoms.atomId(.__call)), null) != null)
        return obj;

    if (obj.isString() or obj.isTable()) return obj;

    return null;
}

fn toCallable(vm: *VM, obj: Value) !?Value {
    const w = (try wrapIterable(vm, obj)) orelse return null;
    if (w.isFunction()) return w;
    if (w.isTable() and try vm.resolveField(w, Value.new.atom(revo.CoreAtoms.atomId(.__call)), null) != null)
        return w;
    const it_id = try makeIterator(vm, .seq);
    try putState(vm, it_id, .up, w);
    return Value.new.table(it_id);
}

fn toState(vm: *VM, xs: Value) !mem.TableID {
    const w = (try wrapIterable(vm, xs)) orelse
        return error.NotIterable;
    return makeState(vm, w);
}

fn makeState(vm: *VM, obj: Value) !mem.TableID {
    const st_id = try vm.tables.create();
    const st = try vm.tables.get(st_id);
    try st.putRawAtom(revo.CoreAtoms.up.atomId(), obj, vm);
    try st.putRawAtom(revo.CoreAtoms.pos.atomId(), Value.new.num(0), vm);
    try st.putRawAtom(revo.CoreAtoms.phase.atomId(), Value.new.num(0), vm);
    try st.putRawAtom(revo.CoreAtoms.idx.atomId(), Value.new.num(0), vm);
    return st_id;
}

fn makeSeqIterator(vm: *VM, obj: Value) !HostResult {
    const it_id = try makeIterator(vm, .seq);
    try putState(vm, it_id, .up, obj);
    return .data(Value.new.table(it_id));
}

fn makeIterator(vm: *VM, kind: Kind) !mem.TableID {
    const it_id = try vm.tables.create();
    const it = try vm.tables.get(it_id);
    try it.putRawAtom(revo.CoreAtoms.kind.atomId(), Value.new.num(@as(f64, @floatFromInt(@backingInt(kind)))), vm);
    const next_id = try vm.installHost("iter_next", .{
        .arity = 1,
        .param_types = &.{.any},
        .func = iteratorNext,
    });
    try it.putRawAtom(revo.CoreAtoms.__call.atomId(), Value.new.function(next_id), vm);
    if (vm.builtin_globals.get(try vm.internAtom("iter"))) |iter_val| {
        if (iter_val.asTable()) |iter_tid| {
            try vm.setTableMetatable(it_id, iter_tid);
        }
    }
    return it_id;
}

fn putState(vm: *VM, it_id: mem.TableID, comptime k: revo.CoreAtoms, val: Value) !void {
    try (try vm.tables.get(it_id)).putRawAtom(k.atomId(), val, vm);
}

fn pullStep(vm: *VM, st_id: mem.TableID, out: *Value, out_idx: *Value) !bool {
    var st = try vm.tables.get(st_id);
    const up = st.getRawAtom(revo.CoreAtoms.up.atomId(), vm) orelse return false;

    const callable = up.isFunction() or
        (up.isTable() and try vm.resolveField(up, Value.new.atom(revo.CoreAtoms.atomId(.__call)), null) != null);
    if (callable) {
        const v = try vm.callFunctionParts(up, null, &.{}, null);
        if (isDone(v)) return false;
        st = try vm.tables.get(st_id);
        const idx_val = st.getRawAtom(revo.CoreAtoms.idx.atomId(), vm) orelse Value.new.num(0);
        out.* = v;
        out_idx.* = idx_val;
        try st.putRawAtom(revo.CoreAtoms.idx.atomId(), Value.new.num(idx_val.asNumOpt().? + 1), vm);
        return true;
    }

    const phase_val = st.getRawAtom(revo.CoreAtoms.phase.atomId(), vm) orelse Value.new.num(0);
    var phase = phase_val.asNumOpt().?;
    const pos_val = st.getRawAtom(revo.CoreAtoms.pos.atomId(), vm) orelse Value.new.num(0);
    var pos = root.host.numToInt(usize, pos_val.asNumOpt().?) orelse return false;

    if (phase == 0) {
        const yielded = switch (up.tag()) {
            .string => blk: {
                const str = vm.stringValue(up.asString().?);
                if (pos >= str.len) break :blk false;
                out.* = try vm.ownValueString(str[pos .. pos + 1]);
                break :blk true;
            },
            .table => blk: {
                const table_id = up.asTable().?;
                const t = try vm.tables.get(table_id);
                if (pos < t.array.items.len) {
                    out.* = t.array.items[pos];
                    break :blk true;
                }
                break :blk false;
            },
            else => return false,
        };
        out_idx.* = Value.new.num(@as(f64, @floatFromInt(pos)));
        if (yielded) {
            st = try vm.tables.get(st_id);
            try st.putRawAtom(revo.CoreAtoms.pos.atomId(), Value.new.num(@as(f64, @floatFromInt(pos + 1))), vm);
            return true;
        }
        if (up.tag() != .table) return false;

        const table_id = up.asTable().?;
        var entries = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, 0);
        defer entries.deinit(vm.runtime.alloc);
        {
            const t = try vm.tables.get(table_id);
            var hash_it = t.hash.orderedIterator();
            while (hash_it.next()) |entry| {
                try entries.append(vm.runtime.alloc, try vm.tableOfSlice(&[_]Value{ entry.key, entry.value }));
            }
        }
        const entries_table = try vm.tableOfSlice(entries.items);
        st = try vm.tables.get(st_id);
        try st.putRawAtom(revo.CoreAtoms.entries.atomId(), entries_table, vm);
        try st.putRawAtom(revo.CoreAtoms.phase.atomId(), Value.new.num(1), vm);
        try st.putRawAtom(revo.CoreAtoms.pos.atomId(), Value.new.num(0), vm);
        phase = 1;
        pos = 0;
    }

    if (phase == 1) {
        const entries_data = st.getRawAtom(revo.CoreAtoms.entries.atomId(), vm) orelse return false;
        const entries_id = entries_data.asTable() orelse return false;
        const entries = vm.tables.get(entries_id) catch return false;
        if (pos >= entries.array.items.len) return false;
        const pair_data = entries.array.items[pos];
        const pair = vm.tables.get(pair_data.asTable().?) catch return false;
        out.* = pair.array.items[1];
        out_idx.* = pair.array.items[0];
        st = try vm.tables.get(st_id);
        try st.putRawAtom(revo.CoreAtoms.pos.atomId(), Value.new.num(@as(f64, @floatFromInt(pos + 1))), vm);
        return true;
    }
    return false;
}

fn callPred(vm: *VM, f: Value, v: Value, idx: Value) !Value {
    return if (passesIndex(vm, f))
        try vm.callFunctionParts(f, null, &[_]Value{ v, idx }, null)
    else
        try vm.callFunctionParts(f, null, &[_]Value{v}, null);
}

fn passesIndex(vm: *VM, f: Value) bool {
    const fn_id = f.asFunction() orelse return false;
    const func = vm.callable.get(fn_id) catch return false;
    return func.arity() >= 2;
}

inline fn isDone(data: Value) bool {
    if (data.asAtom()) |a| return a == revo.CoreAtoms.atomId(.done);
    return false;
}

inline fn isTruthy(data: Value) bool {
    return !revo.isFalse(data);
}

test "iter functions" {
    try testing.topString(
        \\ iter.collect_string(iter.map("abc", fn(c) "x"))
    , "xxx");

    try testing.topString(
        \\ iter.collect_string(iter.map("", fn(c) "x"))
    , "");

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.map({a = 1, b = 2}, fn(v) v + 10)))
    , 23);

    try testing.topNumber(
        \\ const out = {}
        \\ iter.each({a = 1, b = 2}, fn(v, k) out[k] = v + 10)
        \\ out.a
    , 11);

    try testing.topNumber(
        \\ iter.reduce({1, 2, 3, 4}, fn(acc, x) acc + x, 0)
    , 10);

    try testing.topNumber(
        \\ iter.reduce(iter.map({1, 2, 3}, fn(x) x * 2), fn(acc, x) acc + x, 0)
    , 12);

    try testing.topNumber(
        \\ iter.reduce("abc", fn(acc, c) acc + 1, 0)
    , 3);

    try testing.topNumber(
        \\ iter.reduce("", fn(acc, c) acc + 1, 42)
    , 42);

    try testing.topAtom(
        \\ iter.each({1, 2, 3}, fn(x) x)
    , "ok");

    try testing.topAtom(
        \\ iter.each("", fn(c) c)
    , "ok");

    try testing.topNumber(
        \\ const it = iter.filter({1, 2, 3, 4, 5}, fn(x) x > 3)
        \\ it() + it()
    , 9);

    try testing.topNumber(
        \\ iter.find({1, 2, 3, 4}, fn(x) x > 2)
    , 3);

    try testing.topNil(
        \\ iter.find({1, 2}, fn(x) x > 10)
    );

    try testing.topTrue(
        \\ iter.all?({1, 2, 3}, fn(x) x > 0)
    );

    try testing.topFalse(
        \\ iter.all?({1, 2, 0}, fn(x) x > 0)
    );

    try testing.topFalse(
        \\ iter.any?({1, 2}, fn(x) x > 10)
    );

    try testing.topTrue(
        \\ iter.any?({0, 0, 3}, fn(x) x > 2)
    );

    try testing.topTrue(
        \\ iter.all?("", fn(x) 0)
    );

    try testing.topFalse(
        \\ iter.any?("", fn(x) 0)
    );
}

test "iter lazy transforms" {
    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.take({1, 2, 3, 4}, 2)))
    , 3);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.drop({1, 2, 3, 4}, 2)))
    , 7);

    try testing.topNumber(
        \\ iter.collect(iter.take({1, 2, 3}, 0)):len()
    , 0);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.take({1, 2}, 5)))
    , 3);

    try testing.topNumber(
        \\ iter.collect(iter.drop({1, 2}, 5)):len()
    , 0);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.flat_map({1, 2}, fn(x) {x, x * 10})))
    , 33);

    try testing.topNumber(
        \\ {1, 2, 3, 4}
        \\     |> iter.map(fn(x) x * 2)
        \\     |> iter.filter(fn(x) x > 4)
        \\     |> iter.collect()
        \\     |> iter.sum()
    , 14);

    try testing.topString(
        \\ iter.collect_string(iter.filter("hello", fn(c) c != "l"))
    , "heo");
}

test "iter range" {
    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.range(5)))
    , 10);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.range(1, 5)))
    , 10);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.range(0, 10, 2)))
    , 20);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.range(5, 0, -1)))
    , 15);

    try testing.topNumber(
        \\ let total = 0
        \\ for x in iter.range(4) do total = total + x end
        \\ total
    , 6);
}

test "iter fold count sum" {
    try testing.topNumber(
        \\ iter.fold({1, 2, 3, 4}, fn(a, x) a + x)
    , 10);

    try testing.topNil(
        \\ iter.fold({}, fn(a, x) a + x)
    );

    try testing.topNumber(
        \\ iter.count({1, 2, 3, 4})
    , 4);

    try testing.topNumber(
        \\ iter.count({1, 2, 3, 4}, fn(x) x > 2)
    , 2);

    try testing.topNumber(
        \\ iter.count(iter.range(10), fn(x) x % 2 == 0)
    , 5);

    try testing.topNumber(
        \\ iter.sum({1, "x", 3})
    , 4);

    try testing.topNumber(
        \\ iter.sum({a = 1, b = "y", c = 3})
    , 4);
}

test "iter index callbacks and state hiding" {
    try testing.topNumber(
        \\ let last = -1
        \\ iter.each({10, 20}, fn(v, i) last = i)
        \\ last
    , 1);

    try testing.topNumber(
        \\ let total = 0
        \\ for x, i in {7, 8} do total = total + x + i end
        \\ total
    , 16);

    try testing.topNumber(
        \\ const it = iter.map({1, 2, 3}, fn(x) x)
        \\ it:len()
    , 4);

    try testing.topString(
        \\ const out = {}
        \\ iter.each({a = 1, b = 2}, fn(v, k) out:push(k))
        \\ out[0] ~ out[1]
    , ":a:b");

    try testing.topAtom(
        \\ let k = :none
        \\ iter.find({a = 1, b = 2}, fn(v, key) do k = key; :true end)
        \\ k
    , "a");
}

test "iter Host closures can allocate tables without corrupting pools" {
    try testing.topNumber(
        \\ const xs = {}
        \\ xs:push("abc")
        \\ xs:push("")
        \\ const wrap = fn(f) do
        \\     iter.reduce(f, fn(acc, c) do acc:push(c); acc end, {})
        \\ end
        \\ iter.collect(iter.map(xs, wrap))[0]:len()
    , 3);

    try testing.topAtom(
        \\ const xs = {}
        \\ xs:push("abc")
        \\ xs:push("")
        \\ const wrap = fn(f) do
        \\     iter.reduce(f, fn(acc, c) do acc:push(c); acc end, {})
        \\     :done
        \\ end
        \\ iter.each(xs, fn(f) do wrap(f) end)
    , "ok");

    try testing.topNumber(
        \\ iter.reduce({1, 2, 3}, fn(acc, n) do
        \\     const t = {}
        \\     t:push("x")
        \\     acc + 1
        \\ end, 0)
    , 3);
}

test "iter method chaining" {
    try testing.topNumber(
        \\ to_iter({1, 2, 3, 4, 5})
        \\   :map(fn(x) x * 2)
        \\   :filter(fn(x) x / 1.5 > 3)
        \\   :collect()
        \\   |> iter.sum()
    , 24);

    try testing.topNumber(
        \\ {1, 2, 3, 4, 5}
        \\   |> iter.map(fn(x) x * 2)
        \\   |> iter.filter(fn(x) x / 1.5 > 3)
        \\   |> iter.collect()
        \\   |> iter.sum()
    , 24);

    try testing.topNumber(
        \\ iter.range(5)
        \\   :map(fn(x) x + 1)
        \\   :collect()
        \\   |> iter.sum()
    , 15);
}

const std = @import("std");

const revo = @import("../root.zig");
const Value = revo.Value;
const VM = revo.VM;
const root = @import("root.zig");
const specs = @import("specs.zig");
const mem = revo.memory;
const HostResult = root.host.HostResult;
const typeof = root.typeof;
const testing = revo.lang.test_helpers;
