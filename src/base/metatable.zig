// debug flags
pub fn set_debug(args: []const Value, vm: *VM) !HostResult {
    const table_id = args[0].asTable() orelse return .errType(0, "table", base.typeof(args[0], vm));
    const table = try vm.tables.get(table_id);
    vm.debug.dump = try checkField("dump", table, vm);
    vm.debug.each_instr = try checkField("instr", table, vm);
    vm.debug.each_stack = try checkField("stack", table, vm);
    vm.debug.trace = try checkField("trace", table, vm);
    return HostResult.coreAtom(.ok);
}

// get metatable
pub fn get_meta(args: []const Value, vm: *VM) !HostResult {
    const mt = try vm.getMetatableId(args[0]);
    return if (mt) |id| .data(Value.new.table(id)) else .data(revo.Value.new.core(.undef));
}

/// > set_meta(tbl: table, meta: table) -> table
/// returns table with the mt set
///     t = {}
///     mt = {get_val = fn() 42}
///     set_meta(t, mt)
pub fn set_meta(args: []const Value, vm: *VM) !HostResult {
    const mt = if (args[1].asAtom()) |a|
        if (a == revo.CoreAtoms.atomId(.undef)) null else return .errType(1, "undef atom or table", "atom")
    else if (args[1].asTable()) |id|
        id
    else
        return .errType(1, "undef atom or table", base.typeof(args[1], vm));
    try vm.setMetatable(args[0], mt);
    return .data(args[0]);
}

fn checkField(name: []const u8, table: *revo.table.Table, vm: *VM) !bool {
    if (table.getRawAtom(try vm.internAtom(name), vm)) |v| return !revo.isFalse(v);
    return !revo.isFalse((try table.get(try vm.ownValueString(name), vm)) orelse Value.new.nil());
}

test "all lens" {
    try testing.topNumber("len({ 1, 2, 3, 8 }) + len(\"asdf\")", 8);
}

const revo = @import("../root.zig");
const testing = revo.lang.test_helpers;
const Value = revo.Value;
const VM = revo.VM;
const base = @import("root.zig");
const HostResult = base.host.HostResult;
