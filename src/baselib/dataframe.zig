const std = @import("std");
const revo = @import("revo");
const root = @import("root.zig");
const specs = @import("specs.zig");
const table_std = @import("table.zig");
// const alloc_pool = @import("alloc_pool.zig");
const Args = root.host.ArgTypes;

const memory = revo.memory;
const Value = memory.Value;
const VM = revo.VM;
const HostResult = root.host.HostResult;
const Table = revo.table.Table;
const testing = revo.lang.test_helpers;
const table_methods = table_std.Impl;
const root_methods = root.Impl;

// type Dataframe = table<string, table<any>>
fn len_internal(vm: *VM, frame_table: Table) !usize {
    var df_cols_itr = frame_table.hash.orderedIterator();
    var col_array_table: *Table = undefined;
    var count: usize = 0;

    while (df_cols_itr.next()) |kv| {
        if (count != 0) {
            col_array_table = try vm.tables.get(kv.value.asTable().?);
            if (col_array_table.array.items.len != count) {
                return error.NonMatchingColumnLengths;
            }
        } else {
            col_array_table = try vm.tables.get(kv.value.asTable().?);
            count = col_array_table.array.items.len;
        }
    }

    return count;
}

fn copy_df_columns_empty(vm: *VM, frame_table: *Table) !memory.TableID {
    // Create a new result Dataframe with empty copied columns
    const result_table_id = try vm.tables.create();
    const result_table = try vm.tables.get(result_table_id);
    var df_cols_itr = frame_table.hash.orderedIterator();
    while (df_cols_itr.next()) |kv| {
        try result_table.put(result_table_id, vm, kv.key, Value.new.table(try vm.tables.create()));
    }
    return result_table_id;
}

const DFRowIterator = struct {
    frame_table: *const Table,
    len: usize,
    cur_idx: usize,
    vm: *VM,

    pub fn next(itr: *DFRowIterator) !?Value {
        if (itr.cur_idx == itr.len) return null;

        // Extract the values into a tuple table where the atom keys are the column names
        const row_table_id = try itr.vm.tables.create();
        const row_table = try itr.vm.tables.get(row_table_id);
        var df_cols_itr = itr.frame_table.hash.orderedIterator();

        while (df_cols_itr.next()) |kv| {
            const col_table_id = kv.value.asTable().?;
            const col_table = try itr.vm.tables.get(col_table_id);
            try row_table.put(row_table_id, itr.vm, kv.key, col_table.getRaw(Value.new.num(itr.cur_idx), itr.vm).?);
        }

        itr.cur_idx += 1;
        return Value.new.table(row_table_id);
    }
};

fn getDFRowIterator(frame_table: *const Table, vm: *VM) !DFRowIterator {
    const frame_table_len: usize = try len_internal(vm, frame_table.*);
    return .{ .frame_table = frame_table, .len = frame_table_len, .cur_idx = 0, .vm = vm };
}

pub const Impl = struct {

    // dataframe.len(Dataframe) -> number
    pub fn len(vm: *VM, frame_table_id: Args.table) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        var df_cols_itr = frame_table.hash.orderedIterator();
        var col_array_table: *Table = undefined;
        var count: ?usize = null;

        while (df_cols_itr.next()) |kv| {
            if (count) |count_val| {
                col_array_table = try vm.tables.get(kv.value.asTable().?);
                if (col_array_table.array.items.len != count_val) {
                    return error.NonMatchingColumnLengths;
                }
            } else {
                col_array_table = try vm.tables.get(kv.value.asTable().?);
                count = col_array_table.array.items.len;
            }
        }

        return .data(Value.new.num(@as(f64, @floatFromInt(count.?))));
    }

    // dataframe.row(Dataframe, number) -> table
    pub fn row(vm: *VM, frame_table_id: Args.table, idx: Args.number) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        var df_rows_itr = try getDFRowIterator(frame_table, vm);
        var row_idx: usize = 0;
        // For each row in the frame table
        while (try df_rows_itr.next()) |row_table| {
            if (row_idx == @as(usize, @intFromFloat(idx))) return .data(row_table);
            row_idx += 1;
        }
        return .errType(1, "dataframe with len > requested row index", "dataframe row index out of range");
    }

    // dataframe.select(Dataframe, table<string>) -> Dataframe
    pub fn select(vm: *VM, frame_table_id: Args.table, names_table_id: Args.table) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        const names_table = try vm.tables.get(@backingInt(names_table_id));
        const result_table_id = try vm.tables.create();
        const result_table = try vm.tables.get(result_table_id);

        // In order of strings given to the select() function
        for (names_table.array.items) |colname| {
            // if the array string is in the hashmap
            const maybe_coltable = frame_table.getRaw(colname, vm);
            if (maybe_coltable) |coltable| {
                // clone it, place it in the result table under the same string name
                const copied_table_id = switch (try table_methods.copy(vm, @fromBackingInt(@intCast(coltable.asTable().?)))) {
                    .ok => |v| v.asTable().?,
                    .err => |e| return .{ .err = e },
                };
                try result_table.put(result_table_id, vm, colname, Value.new.table(copied_table_id));
            }
        }

        return .data(Value.new.table(result_table_id));
    }

    // dataframe.map(Dataframe, function) -> Dataframe
    pub fn map(vm: *VM, frame_table_id: Args.table, new_col_name: Args.string, f: Args.function) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        var df_rows_itr = try getDFRowIterator(frame_table, vm);
        const new_col_table_id = try vm.tables.create();
        const new_col_table = try vm.tables.get(new_col_table_id);

        // For each row in the frame table
        while (try df_rows_itr.next()) |row_table| {
            // Apply the function to the row
            const map_res = try vm.callFunctionParts(Value.new.function(@backingInt(f)), null, &[_]Value{row_table}, null);
            // Add the result to the new column table
            try new_col_table.push(vm.runtime.alloc, map_res);
        }

        // Copy the original table
        const result_table_id = switch (try table_methods.deep_copy(vm, frame_table_id)) {
            .ok => |v| v.asTable().?,
            .err => |e| return .{ .err = e },
        };
        const result_table = try vm.tables.get(result_table_id);
        // Add the new column table to it with the new key
        try result_table.put(result_table_id, vm, Value.new.str(@backingInt(new_col_name)), Value.new.table(new_col_table_id));
        // Return the resulting table
        return HostResult.data(Value.new.table(result_table_id));
    }

    // dataframe.filter(Dataframe, function) -> Dataframe
    pub fn filter(vm: *VM, frame_table_id: Args.table, f: Args.function) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        var df_rows_itr = try getDFRowIterator(frame_table, vm);

        // Create a result dataframe with the same columns as the input Dataframe
        const result_table_id = try copy_df_columns_empty(vm, frame_table);
        const result_table = try vm.tables.get(result_table_id);

        // For each row in the input Dataframe
        while (try df_rows_itr.next()) |row_table_val| {
            // Apply the function to the row
            const filter_res = try vm.callFunctionParts(Value.new.function(@backingInt(f)), null, &[_]Value{row_table_val}, null);
            if (!filter_res.isAtom()) return .errType(1, "filter predicate that returns boolean :true or :false", "filter predicate doesn't return boolean");
            const filter_res_id = filter_res.asAtom().?;

            // If the function returns true
            if (filter_res_id == @backingInt(revo.CoreAtoms.true)) {
                const row_table_id = row_table_val.asTable().?;
                const row_table = try vm.tables.get(row_table_id);

                // Append that row's values to the result Dataframe
                var df_cols_itr = result_table.hash.orderedIterator();
                while (df_cols_itr.next()) |kv| {
                    const result_col_ele = row_table.getRaw(kv.key, vm).?;

                    const result_col_table_id = kv.value.asTable().?;
                    const result_col_table = try vm.tables.get(result_col_table_id);

                    // Append it to the result dataframe's column
                    try result_col_table.array.append(vm.runtime.alloc, result_col_ele);
                } 
            }
        }

        // Return the resulting table
        return HostResult.data(Value.new.table(result_table_id));
    }

    // dataframe.sort(Dataframe, function) -> Dataframe
    pub fn sort(vm: *VM, frame_table_id: Args.table, f: Args.function) !HostResult {
        const frame_table = try vm.tables.get(@backingInt(frame_table_id));
        var df_rows_itr = try getDFRowIterator(frame_table, vm);
        var df_cols_itr = frame_table.hash.orderedIterator();

        // Apply the function to each row in the DF as a new list of (idx, res)
        const RowResult = struct {idx: u64, f_result: Value};
        var row_results_list: std.ArrayList(RowResult) = .empty;
        defer row_results_list.deinit(vm.runtime.alloc);

        var row_idx: usize = 0;
        // For each row in the frame table
        while (try df_rows_itr.next()) |row_table| {
            // Apply the function to the row
            const map_res = try vm.callFunctionParts(Value.new.function(@backingInt(f)), null, &[_]Value{row_table}, null);
            // Add the f result to the new column table
            try row_results_list.append(vm.runtime.alloc, .{.idx = row_idx, .f_result = map_res});
            row_idx += 1;
        }

        // Sort the list by f result
        const Context = struct {
            vm_: *VM,
            pub fn lessThanFn(ctx: @This(), lhs: RowResult, rhs: RowResult) bool {
                return ctx.vm_.compare(lhs.f_result, rhs.f_result) == .lt;
            }
        };
        std.mem.sort(RowResult, row_results_list.items, Context{ .vm_ = vm }, Context.lessThanFn);

        // Create a new result Dataframe with empty copied columns
        const result_table_id = try copy_df_columns_empty(vm, frame_table);
        const result_table = try vm.tables.get(result_table_id);

        // For each result
        for (row_results_list.items) |row_result| {
            // For each column
            df_cols_itr = frame_table.hash.orderedIterator();
            while (df_cols_itr.next()) |kv| {
                // Get the element at the result's index
                const col_table_id = kv.value.asTable().?;
                const col_table = try vm.tables.get(col_table_id);
                const col_ele = col_table.getRaw(Value.new.num(row_result.idx), vm).?;

                // Append it to the result dataframe's column
                const result_col_table_id = result_table.getRaw(kv.key, vm).?.asTable().?;
                const result_col_table = try vm.tables.get(result_col_table_id);
                try result_col_table.array.append(vm.runtime.alloc, col_ele);
            }
        }

        // Return the result dataframe
        return HostResult.data(Value.new.table(result_table_id));
    }

    // dataframe.stack(table<Dataframe>) -> Dataframe
        // Ensure each Dataframe in the input table has matching column names and types
        // Create a result dataframe with the same columns
        // For each Dataframe in the input table
            // Append that Dataframe's columns to the current result columns
        // Return the result dataframe

    // dataframe.rename(Dataframe, string, string) -> Dataframe
        // Create a result dataframe with every column copied except the renamed one
        // Copy the source column with the new name
        // Return the result dataframe

    // dataframe.inner_join(table<Dataframe>, string) -> Dataframe
        // Ensure the input dataframes all have a join column named the input string of matching type
        // Pull out the first Dataframe's join column as a list
        // Create a result Dataframe and add the join column as an array table
        // For each input Dataframe in the input table
            // For each column in the current Dataframe not in the result Dataframe
                // For each value in the join column
                    // For each index in the new column to be added
                        // If the value in the join column matches the value at the input Dataframe's join column index
                            // Append the value in the new column at that index
                            // continue
        // Return the result dataframe

    // dataframe.unique(Dataframe, table<string>) -> Dataframe
        // Initiate a AutoHashMap of <f64, bool> to track seen row values
        // Initiate a result Dataframe
        // For each row in the input Dataframe
            // Set an accumulator to the root.hash() of the first column in the string table
            // For each other column in the string table
                // Mod the accumulator with the root.hash() of that value
            // If the resulting hash is in the seen hashmap, continue
            // Otherwise, push the row values on the result table, and add the hash to the seen hashmap
        // Return the result dataframe


};

pub const impls: []const specs.Impl = root.host.impls(Impl).val;

// dataframe.group_by(Frame) -> Dataframe
// dataframe.transpose(Frame) -> Dataframe

test "frame functions and methods" {
    try testing.topTrue("{\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {7, 8, 9}} |> dataframe.row(1) == {\"foos\" = 2, \"bars\" = 5, \"bazzes\" = 8}");
    try testing.topTrue("{\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {7, 8, 9}} |> dataframe.select({\"foos\", \"bazzes\"}) == {\"foos\" = {1, 2, 3}, \"bazzes\" = {7, 8, 9}}");
    try testing.topTrue("{\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {7, 8, 9}} |> dataframe.len() == 3");
    try testing.topTrue("dataframe.map({\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}}, \"bazzes\", fn (row) row[\"foos\"] * row[\"bars\"]) == {\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {4, 10, 18}}");
    try testing.topTrue("dataframe.filter({\"foos\" = {1, 2, 3, 4}, \"bars\" = {4, 5, 6, 7}}, fn (row) row[\"foos\"] % 2 == 0) == {\"foos\" = {2, 4}, \"bars\" = {5, 7}}");
    try testing.topTrue("dataframe.sort({\"foos\" = {3, 1, 2}, \"bars\" = {4, 5, 6}}, fn (row) row[\"foos\"]) == {\"foos\" = {1, 2, 3}, \"bars\" = {5, 6, 4}}");
}
