// debug flags
pub fn set_debug(args: []const Data, vm: *VM) !NativeResult {
    const table_id = args[0].asTable() orelse return .errType(0, "table", std_lib.dataToString(args[0]));
    const table = try vm.tables.get(table_id);
    vm.debug.dump = try check_field("dump", table, vm);
    vm.debug.each_instr = try check_field("instr", table, vm);
    vm.debug.each_stack = try check_field("stack", table, vm);
    vm.debug.trace = try check_field("trace", table, vm);
    return std_lib.okAtom(vm);
}

// get metatable
pub fn get_metatable_(args: []const Data, vm: *VM) !NativeResult {
    const mt = try vm.getMetatableId(args[0]);
    return if (mt) |id| .{ .ok = Data.new.table(id) } else .{ .ok = revo.Data.new.core(.missing) };
}

/// > set_metatable(tbl: table, meta: table) -> table
/// returns table with the mt set
///     t = {}
///     mt = {get_val = fn() 42}
///     set_metatable(t, mt)
pub fn set_metatable_(args: []const Data, vm: *VM) !NativeResult {
    const mt = if (args[1].asAtom()) |a|
        if (a == revo.core_atoms.atom_id(.nil)) null else return .errType(1, "nil atom or table", "atom")
    else if (args[1].asTable()) |id|
        id
    else
        return .errType(1, "nil atom or table", std_lib.dataToString(args[1]));
    try vm.setMetatable(args[0], mt);
    return .{ .ok = args[0] };
}

fn check_field(name: []const u8, table: *revo.table.Table, vm: *VM) !bool {
    return !revo.isFalse((try table.get(try vm.ownDataString(name), vm)) orelse Data.new.nil());
}

test "all lens" {
    try testing.top_number("len({ 1, 2, 3, 8 }) + len(\"asdf\")", 8);
}

const revo = @import("../root.zig");
const testing = revo.lang.testing;
const Data = revo.Data;
const VM = revo.VM;
const std_lib = @import("root.zig");
const NativeResult = std_lib.NativeResult;
