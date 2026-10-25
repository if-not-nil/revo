const revo = @import("revo");
const root = @import("root.zig");
const specs = @import("specs.zig");
const std = @import("std");
const table_std = @import("table.zig");
// const alloc_pool = @import("alloc_pool.zig");
const Args = root.host.ArgTypes;

const math = std.math;
const memory = revo.memory;
const Value = memory.Value;
const VM = revo.VM;
const HostResult = root.host.HostResult;
const testing = revo.lang.test_helpers;
const table_methods = table_std.Impl;

//
// RunningStats
//
// An accumulator for statistical data.
// Originally formulated by Donald Knuth in "The Art of Computer Programming".
//

const RunningStats = struct {
    // amount of pushed data
    n: usize = 0,
    // self-explaining
    min: f64 = 0.0,
    max: f64 = 0.0,
    sum: f64 = 0.0,
    ssq: f64 = 0.0,
    prd: f64 = 0.0,
    // statistical moments, mom1 is mean
    mom1: f64 = 0.0,
    mom2: f64 = 0.0,
    mom3: f64 = 0.0,
    mom4: f64 = 0.0,
    // compensation variables for float precision
    cmp1: f64 = 0.0,
    cmp2: f64 = 0.0,
    cmp3: f64 = 0.0,
    cmp4: f64 = 0.0,
    // cmp1: std.atomic.Value(f64) = std.atomic.Value(f64).init(0.0),
    // cmp2: std.atomic.Value(f64) = std.atomic.Value(f64).init(0.0),
    // cmp3: std.atomic.Value(f64) = std.atomic.Value(f64).init(0.0),
    // cmp4: std.atomic.Value(f64) = std.atomic.Value(f64).init(0.0),
    // hashmap for tracking frequencies
    freq: std.AutoHashMap(u64, usize),
    imode: f64 = undefined,
    imode_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) RunningStats {
        return .{
            .freq = std.AutoHashMap(u64, usize).init(allocator),
        };
    }
    pub fn deinit(self: *RunningStats) void {
        self.freq.deinit();
    }

    pub fn n_float(self: *RunningStats) f64 {
        return @as(f64, @floatFromInt(self.n));
    }

    fn pushEle(self: *RunningStats, x: f64) !void {
        // Pushes a value `x` for processing.
        if (self.n == 0) {
            self.min = x;
            self.max = x;
        } else {
            if (self.min > x)
                self.min = x;
            if (self.max < x)
                self.max = x;
        }
        self.n += 1;
        // See Knuth TAOCP vol 2, 3rd edition, page 232
        self.sum += x;
        self.ssq += x * x;
        if (self.n == 1) {
            self.prd = x;
        } else {
            self.prd *= x;
        }

        const entry = try self.freq.getOrPut(@bitCast(x));
        if (!entry.found_existing) {
            entry.value_ptr.* = 1;
        } else {
            entry.value_ptr.* += 1;
        }
        const this_count = entry.value_ptr.*;
        // match numpy behaviour, on ties it'll choose the smaller value
        if (this_count > self.imode_count or
            (this_count == self.imode_count and x < self.imode))
        {
            self.imode_count = this_count;
            self.imode = x;
        }

        const nf = self.n_float();

        // 1. Calculate deltas
        const delta = x - self.mom1;
        const delta_n = delta / nf;
        const delta_n2 = delta_n * delta_n;
        const term1 = delta * delta_n * (nf - 1);

        // 2. Compute the exact increments
        const delta_mom4 = term1 * delta_n2 * (nf * nf - 3.0 * nf + 3.0) + (6.0 * delta_n2 * self.mom2) - (4.0 * delta_n * self.mom3);
        const delta_mom3 = term1 * delta_n * (nf - 2.0) - (3.0 * delta_n * self.mom2);
        const delta_mom2 = term1;
        const delta_mom1 = delta_n;

        // 3. Apply Kahan Summation to preserve low-order bits
        // Accumulate mom4
        const y4 = delta_mom4 - self.cmp4;
        const t4 = self.mom4 + y4;
        self.cmp4 = (t4 - self.mom4) - y4;
        self.mom4 = t4;

        // Accumulate mom3
        const y3 = delta_mom3 - self.cmp3;
        const t3 = self.mom3 + y3;
        self.cmp3 = (t3 - self.mom3) - y3;
        self.mom3 = t3;

        // Accumulate mom3
        const y2 = delta_mom2 - self.cmp2;
        const t2 = self.mom2 + y2;
        self.cmp2 = (t2 - self.mom2) - y2;
        self.mom2 = t2;

        // Accumulate mom1 (Mean)
        const y1 = delta_mom1 - self.cmp1;
        const t1 = self.mom1 + y1;
        self.cmp1 = (t1 - self.mom1) - y1;
        self.mom1 = t1;
    }

    fn pushValue(self: *RunningStats, data: *std.ArrayList(f64)) !void {
        for (data.items) |value| {
            try self.pushEle(value);
        }
    }

    // callers to surface a proper HostResult error instead of panicking
    // when the table contains a non-numeric element
    fn pushTableValue(self: *RunningStats, data: []const Value) !void {
        for (data) |value| {
            const num = value.asNumOpt() orelse return error.NonNumericValue;
            try self.pushEle(num);
        }
    }

    fn mean(self: *RunningStats) f64 {
        // Computes the current mean of `self`.
        return self.mom1;
    }

    fn geomean(self: *RunningStats) f64 {
        // Computes the current mean of `self`.
        return math.pow(f64, self.prd, 1 / self.n_float());
    }

    fn mode(self: *RunningStats) f64 {
        // Computes the current mode of `self`.
        return self.imode;
    }

    fn variance(self: *RunningStats) f64 {
        // Computes the current population variance of `self`.
        return self.mom2 / self.n_float();
    }

    fn varianceS(self: *RunningStats) f64 {
        // Computes the current sample variance of `self`.
        if (self.n <= 1) return 0.0;

        const nm1_float = self.n_float() - 1.0;
        return self.mom2 / nm1_float;
    }

    fn standardDeviation(self: *RunningStats) f64 {
        // Computes the current population standard deviation of `self`.
        return math.sqrt(self.variance());
    }

    fn standardDeviationS(self: *RunningStats) f64 {
        // Computes the current sample standard deviation of `self`.
        return math.sqrt(self.varianceS());
    }

    fn skewness(self: *RunningStats) f64 {
        // Computes the current population skewness of `self`.
        return math.sqrt(self.n_float()) * self.mom3 / math.pow(f64, self.mom2, 1.5);
    }

    fn skewnessS(self: *RunningStats) f64 {
        // Computes the current sample skewness of `self`.
        if (self.n <= 2) return 0.0;

        const nf = self.n_float();
        const nm2_float = nf - 2.0;
        const s2 = self.skewness();
        return math.sqrt(nf * (nf - 1)) * s2 / nm2_float;
    }

    fn kurtosis(self: *RunningStats) f64 {
        // Computes the current population kurtosis of `self`.
        return self.n_float() * self.mom4 / (self.mom2 * self.mom2) - 3.0;
    }

    fn kurtosisS(self: *RunningStats) f64 {
        // Computes the current sample kurtosis of `self`.
        if (self.n <= 3) return 0.0;

        const nf = self.n_float();
        const nm1_float = nf - 1.0;
        const np1_float = nf + 1.0;
        const nm2_x_nm3_float = (nf - 2.0) * (nf - 3.0);
        return nm1_float / nm2_x_nm3_float * (np1_float * self.kurtosis() + 6);
    }
};

test "RunningStats struct and methods" {
    const a = std.testing.allocator;
    const expect = std.testing.expect;

    var list: std.ArrayList(f64) = .empty;
    defer list.deinit(a);
    try list.appendSlice(a, &.{ 1.0, 2.0, 1.0, 4.0, 1.0, 4.0, 1.0, 2.0 });

    var runningStats: RunningStats = RunningStats.init(a);
    defer runningStats.deinit();
    try runningStats.pushValue(&list);
    const tolerance = 0.00001;

    try expect(runningStats.n == 8);
    try std.testing.expectApproxEqAbs(runningStats.mean(), 2.0, tolerance);
    try std.testing.expectApproxEqAbs(runningStats.variance(), 1.5, tolerance);
    try std.testing.expectApproxEqAbs(runningStats.varianceS(), 1.714285714285715, tolerance);
    try std.testing.expectApproxEqAbs(runningStats.skewness(), 0.8164965809277261, tolerance);
    try std.testing.expectApproxEqAbs(runningStats.skewnessS(), 1.018350154434631, tolerance);
    try std.testing.expectApproxEqAbs(runningStats.kurtosis(), -1.0, tolerance);
    try std.testing.expectApproxEqAbs(runningStats.kurtosisS(), -0.7000000000000008, tolerance);
}

// zig fmt: off
const RunningRegress = struct { // An accumulator for regression calculations.
    n: usize = 0,               // amount of pushed data
    x_stats: RunningStats,      // stats for the first set of data
    y_stats: RunningStats,      // stats for the second set of data
    s_xy: f64 = 0.0,            // accumulated data for combined xy
    // zig fmt: on

    pub fn init(allocator: std.mem.Allocator) RunningRegress {
        return .{
            .x_stats = RunningStats.init(allocator),
            .y_stats = RunningStats.init(allocator),
        };
    }
    pub fn deinit(self: *RunningRegress) void {
        self.x_stats.deinit();
        self.y_stats.deinit();
    }

    pub fn n_float(self: *RunningRegress) f64 {
        return @as(f64, @floatFromInt(self.n));
    }

    fn pushEles(self: *RunningRegress, x: f64, y: f64) !void {
        // Pushes two values `x` and `y` for processing.
        self.s_xy += (self.x_stats.mean() - x) * (self.y_stats.mean() - y) * self.n_float() / @as(f64, @floatFromInt(self.n + 1));
        try self.x_stats.pushEle(x);
        try self.y_stats.pushEle(y);
        self.n += 1;
    }

    fn pushValue(self: *RunningRegress, x_data: *std.ArrayList(f64), y_data: *std.ArrayList(f64)) !void {
        // Pushes two sets of values `x` and `y` for processing.
        for (0..x_data.items.len) |i| {
            try self.pushEles(x_data.items[i], y_data.items[i]);
        }
    }

    fn pushTableValue(self: *RunningRegress, x_data: []const Value, y_data: []const Value) !void {
        for (x_data, 0..) |value, idx| {
            const x_num = value.asNumOpt() orelse return error.NonNumericValue;
            const y_num = y_data[idx].asNumOpt() orelse return error.NonNumericValue;
            try self.pushEles(x_num, y_num);
        }
    }

    fn slope(self: *RunningRegress) f64 {
        // Computes the slope of `self`.
        const s_xx = self.x_stats.varianceS() * @as(f64, @floatFromInt(self.n - 1));
        return self.s_xy / s_xx;
    }

    fn intercept(self: *RunningRegress) f64 {
        // Computes the intercept of `self`.
        return self.y_stats.mean() - self.slope() * self.x_stats.mean();
    }

    fn correlation(self: *RunningRegress) f64 {
        // Computes the correlation of the two data
        // sets pushed into `self`.
        const t = self.x_stats.standardDeviation() * self.y_stats.standardDeviation();
        return self.s_xy / (self.n_float() * t);
    }

    fn covariance(self: *RunningRegress) f64 {
        // Computes the population covariance of the two data
        // sets pushed into `self`.
        return self.s_xy / self.n_float();
    }

    fn sample_covariance(self: *RunningRegress) f64 {
        // Computes the sample covariance of the two data
        // sets pushed into `self`.
        return self.s_xy / @as(f64, @floatFromInt(self.n - 1));
    }
};

test "RunningRegress struct and methods" {
    const a = std.testing.allocator;
    const expect = std.testing.expect;

    var list_a: std.ArrayList(f64) = .empty;
    var list_b: std.ArrayList(f64) = .empty;
    defer {
        list_a.deinit(a);
        list_b.deinit(a);
    }
    try list_a.appendSlice(a, &.{ 1.0, 2.0, 3.0, 4.0, 5.0 });
    try list_b.appendSlice(a, &.{ 2.0, 3.0, 5.0, 4.0, 6.0 });

    var runningRegress: RunningRegress = RunningRegress.init(a);
    defer runningRegress.deinit();
    try runningRegress.pushValue(&list_a, &list_b);
    const tolerance = 0.00001;

    try expect(runningRegress.n == 5);
    try std.testing.expectApproxEqAbs(runningRegress.slope(), 0.9, tolerance);
    try std.testing.expectApproxEqAbs(runningRegress.intercept(), 1.3, tolerance);
    try std.testing.expectApproxEqAbs(runningRegress.correlation(), 0.9, tolerance);
    try std.testing.expectApproxEqAbs(runningRegress.covariance(), 1.8, tolerance);
    try std.testing.expectApproxEqAbs(runningRegress.sample_covariance(), 2.25, tolerance);
}

pub const Impl = struct {
    fn buildStats(vm: *VM, table_id: Args.table) !RunningStats {
        const table = try vm.tables.get(@backingInt(table_id));

        if (table.array.items.len == 0) {
            return error.EmptyTable;
        }

        var runningStats: RunningStats = RunningStats.init(vm.runtime.alloc);
        errdefer runningStats.deinit();
        try runningStats.pushTableValue(table.array.items);
        return runningStats;
    }

    /// convert a zig error into a HostResult.err for correctness
    /// malformed input has to return a .err error instead of throwing a zig error
    fn statsErrResult(e: anyerror) !HostResult {
        switch (e) {
            error.EmptyTable => return .errType(0, "table with at least 1 element", "no statistics for empty data"),
            error.NonNumericValue => return .errType(0, "table of numbers", "table contains a non-numeric value"),
            error.NonMatchingTables => return .errType(0, "tables of matching length", "table lengths do not match"),
            else => return e,
        }
    }

    fn numStat(vm: *VM, table_id: Args.table, comptime compute: fn (*RunningStats) f64) !HostResult {
        var runningStats = buildStats(vm, table_id) catch |e| return statsErrResult(e);
        defer runningStats.deinit();
        return .data(Value.new.num(compute(&runningStats)));
    }

    /// > stats.frequencies(table) -> table<any>
    /// returns a histogram of element frequencies as table (ele: freq)
    pub fn frequencies(vm: *VM, table_id: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(table_id));
        for (table.array.items) |ele| {
            if (!ele.isNumber()) return nonnumeric_frequencies(vm, table_id);
        }

        var runningStats = buildStats(vm, table_id) catch |e| return statsErrResult(e);
        defer runningStats.deinit();

        const result_table_id = try vm.tables.create();
        const result_table = try vm.tables.get(result_table_id);

        var freq_it = runningStats.freq.iterator();
        while (freq_it.next()) |entry| {
            try result_table.put(result_table_id, vm, Value.new.num(@as(f64, @bitCast(entry.key_ptr.*))), Value.new.num(entry.value_ptr.*));
        }

        return .data(Value.new.table(result_table_id));
    }

    fn nonnumeric_frequencies(vm: *VM, table_id: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(table_id));
        const result_table_id = try vm.tables.create();
        const result = try vm.tables.get(result_table_id);

        for (table.array.items) |ele| {
            if (try result.get(ele, vm)) |this_count_data| {
                try result.put(result_table_id, vm, ele, Value.new.num(this_count_data.asNumOpt().? + 1));
            } else {
                try result.put(result_table_id, vm, ele, Value.new.num(1));
            }
        }

        return .data(Value.new.table(result_table_id));
    }

    // stats.median(table) -> number
    // Middle value of input data.
    pub fn median(vm: *VM, table_id: Args.table) !HostResult {
        // copy instead of doing it ourselves
        const copied_table_id = switch (try table_methods.copy(vm, table_id)) {
            .ok => |v| v.asTable().?,
            .err => |e| return .{ .err = e },
        };

        // can safely unwrap because sort() does not return an error
        const res = (try table_methods.sort(vm, @fromBackingInt(@intCast(copied_table_id)))).ok.asTable().?;

        // good hygiene to drill the latest id you have
        const sorted_table = try vm.tables.get(res);
        const n: usize = sorted_table.array.items.len;

        if (n == 0) {
            return .errType(0, "table with at least 1 element", "no median for empty data");
        } else if (n % 2 == 1) {
            const middle_ele = sorted_table.array.items[n / 2];
            return .data(Value.new.num(middle_ele.asNumOpt().?));
        } else {
            const i: usize = n / 2;
            return .data(Value.new.num((sorted_table.array.items[i - 1].asNumOpt().? + sorted_table.array.items[i].asNumOpt().?) / 2));
        }
    }

    // -- [wrappers] ----------------------------------------------------------
    // do not comptime inline-for this in impls
    //

    // stats.mode(table) -> number
    // Most frequent occuring value of input data.
    pub fn mode(vm: *VM, table_id: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(table_id));

        if (table.array.items.len == 0) {
            return .errType(
                0,
                "table with at least 1 element",
                "no mode for empty table",
            );
        }

        for (table.array.items) |ele| {
            if (!ele.isNumber()) return nonnumeric_mode(vm, table_id);
        }
        return numStat(vm, table_id, RunningStats.mode);
    }

    fn nonnumeric_mode(vm: *VM, table_id: Args.table) !HostResult {
        const table = try vm.tables.get(@backingInt(table_id));
        const data = table.array.items;

        var freq = std.AutoHashMap(Value, usize).init(vm.runtime.alloc);
        defer freq.deinit();

        var mode_val: Value = data[0];
        var max_freq: usize = 0;

        for (data) |value| {
            const entry = try freq.getOrPut(value);

            if (!entry.found_existing) {
                entry.value_ptr.* = 1;
            } else {
                entry.value_ptr.* += 1;
            }

            const count = entry.value_ptr.*;

            // match numpy behaviour, on ties it'll choose the smaller value
            if (count > max_freq or
                (count == max_freq and vm.compare(value, mode_val) == .lt))
            {
                max_freq = count;
                mode_val = value;
            }
        }

        return .data(mode_val);
    }

    // stats.statistics(table) -> table
    // table of all statistics of the input data
    pub fn statistics(vm: *VM, table_id: Args.table) !HostResult {
        var runningStats = buildStats(vm, table_id) catch |e| return statsErrResult(e);
        defer runningStats.deinit();

        const result_table_id = try vm.tables.create();
        const result_table = try vm.tables.get(result_table_id);
        const freq_table_id = try vm.tables.create();
        const freq_table = try vm.tables.get(freq_table_id);

        var freq_it = runningStats.freq.iterator();
        while (freq_it.next()) |entry| {
            try freq_table.put(freq_table_id, vm, Value.new.num(@as(f64, @bitCast(entry.key_ptr.*))), Value.new.num(entry.value_ptr.*));
        }

        try result_table.put(result_table_id, vm, try vm.atomValue("n"), Value.new.num(runningStats.n));
        try result_table.put(result_table_id, vm, try vm.atomValue("frequencies"), Value.new.table(freq_table_id));
        try result_table.put(result_table_id, vm, try vm.atomValue("mean"), Value.new.num(runningStats.mean()));
        try result_table.put(result_table_id, vm, try vm.atomValue("median"), (try median(vm, table_id)).ok);
        try result_table.put(result_table_id, vm, try vm.atomValue("mode"), Value.new.num(runningStats.mode()));
        try result_table.put(result_table_id, vm, try vm.atomValue("geomean"), Value.new.num(runningStats.geomean()));
        try result_table.put(result_table_id, vm, try vm.atomValue("minimum"), Value.new.num(runningStats.min));
        try result_table.put(result_table_id, vm, try vm.atomValue("maximum"), Value.new.num(runningStats.max));
        try result_table.put(result_table_id, vm, try vm.atomValue("sum"), Value.new.num(runningStats.sum));
        try result_table.put(result_table_id, vm, try vm.atomValue("sum_of_squares"), Value.new.num(runningStats.ssq));
        try result_table.put(result_table_id, vm, try vm.atomValue("product"), Value.new.num(runningStats.prd));
        try result_table.put(result_table_id, vm, try vm.atomValue("stdev"), Value.new.num(runningStats.standardDeviation()));
        try result_table.put(result_table_id, vm, try vm.atomValue("sample_stdev"), Value.new.num(runningStats.standardDeviationS()));
        try result_table.put(result_table_id, vm, try vm.atomValue("variance"), Value.new.num(runningStats.variance()));
        try result_table.put(result_table_id, vm, try vm.atomValue("sample_variance"), Value.new.num(runningStats.varianceS()));
        try result_table.put(result_table_id, vm, try vm.atomValue("skewness"), Value.new.num(runningStats.skewness()));
        try result_table.put(result_table_id, vm, try vm.atomValue("sample_skewness"), Value.new.num(runningStats.skewnessS()));
        try result_table.put(result_table_id, vm, try vm.atomValue("kurtosis"), Value.new.num(runningStats.kurtosis()));
        try result_table.put(result_table_id, vm, try vm.atomValue("sample_kurtosis"), Value.new.num(runningStats.kurtosisS()));

        // Encode the internal accumulator values so we can continue accumulating if necessary
        // try result_table.put(result_table_id, vm, try vm.atomValue("moment_1"), Value.new.num(runningStats.mom1));
        // try result_table.put(result_table_id, vm, try vm.atomValue("moment_2"), Value.new.num(runningStats.mom2));
        // try result_table.put(result_table_id, vm, try vm.atomValue("moment_3"), Value.new.num(runningStats.mom3));
        // try result_table.put(result_table_id, vm, try vm.atomValue("moment_4"), Value.new.num(runningStats.mom4));
        // try result_table.put(result_table_id, vm, try vm.atomValue("moment_1_compensation"), Value.new.num(runningStats.cmp1));
        // try result_table.put(result_table_id, vm, try vm.atomValue("moment_2_compensation"), Value.new.num(runningStats.cmp2));
        // try result_table.put(result_table_id, vm, try vm.atomValue("moment_3_compensation"), Value.new.num(runningStats.cmp3));
        // try result_table.put(result_table_id, vm, try vm.atomValue("moment_4_compensation"), Value.new.num(runningStats.cmp4));

        return .data(Value.new.table(result_table_id));
    }

    fn buildRegress(vm: *VM, table_1_id: Args.table, table_2_id: Args.table) !RunningRegress {
        const table_1 = try vm.tables.get(@backingInt(table_1_id));
        const table_2 = try vm.tables.get(@backingInt(table_2_id));

        if (table_1.array.items.len == 0 or table_2.array.items.len == 0) {
            return error.EmptyTable;
        }
        if (table_1.array.items.len != table_2.array.items.len) {
            return error.NonMatchingTables;
        }

        var runningRegress: RunningRegress = RunningRegress.init(vm.runtime.alloc);
        errdefer runningRegress.deinit();
        try runningRegress.pushTableValue(table_1.array.items, table_2.array.items);
        return runningRegress;
    }

    // stats.regression(table) -> table
    // table of all regression statistics of the input data
    pub fn regression(vm: *VM, table_1_id: Args.table, table_2_id: Args.table) !HostResult {
        var runningRegress = buildRegress(vm, table_1_id, table_2_id) catch |e| return statsErrResult(e);
        defer runningRegress.deinit();

        const result_table_id = try vm.tables.create();
        const result_table = try vm.tables.get(result_table_id);

        try result_table.put(result_table_id, vm, try vm.atomValue("n"), Value.new.num(runningRegress.n));
        try result_table.put(result_table_id, vm, try vm.atomValue("sum_of_products"), Value.new.num(runningRegress.s_xy));
        try result_table.put(result_table_id, vm, try vm.atomValue("slope"), Value.new.num(runningRegress.slope()));
        try result_table.put(result_table_id, vm, try vm.atomValue("intercept"), Value.new.num(runningRegress.intercept()));
        try result_table.put(result_table_id, vm, try vm.atomValue("correlation"), Value.new.num(runningRegress.correlation()));
        try result_table.put(result_table_id, vm, try vm.atomValue("covariance"), Value.new.num(runningRegress.covariance()));
        try result_table.put(result_table_id, vm, try vm.atomValue("sample_covariance"), Value.new.num(runningRegress.sample_covariance()));

        return .data(Value.new.table(result_table_id));
    }
};

pub const impls: []const specs.Impl = root.host.impls(Impl).val;

test "stats methods" {
    try testing.topTrue("{1, 1, 1, 2, 3, 3} |> stats.statistics(_).frequencies == {1=3, 2=1, 3=2}");
    try testing.topTrue("{\"hello\", \"world\", \"how say\", \"hello\",} |> stats.frequencies() == {\"hello\"=2, \"world\"=1, \"how say\"=1}");
    try testing.topTrue("{1, 1, 1, 2, 3} |> stats.statistics(_).mean == 1.6");
    try testing.topTrue("{54, 24, 36} |> stats.statistics(_).geomean == 36");
    try testing.topTrue("{3, 1, 2, 1, 1} |> stats.statistics(_).median == 1");
    try testing.topTrue("{3, 1, 2, 1, 3, 1} |> stats.statistics(_).median == 1.5");
    try testing.topTrue("{3, 1, 2, 1, 3, 1} |> stats.statistics(_).mode == 1");
    try testing.topTrue("{\"hello\", \"world\", \"how say\", \"hello\",} |> stats.mode() == \"hello\"");
    try testing.topTrue("{1, 1, 2, 2} |> stats.statistics(_).mode == 1");
    try testing.topTrue("{1.0, 2.0, 1.0, 4.0, 1.0, 4.0, 1.0, 2.0} |> stats.statistics(_).mean == 2.0");
    try testing.topTrue("{1.5, 2.5, 2.5, 2.75, 3.25, 4.75} |> stats.statistics(_).stdev == 0.986893273527251");
    try testing.topTrue("{1.5, 2.5, 2.5, 2.75, 3.25, 4.75} |> stats.statistics(_).sample_stdev == 1.0810874155219827");
    try testing.topTrue("{1.0, 2.0, 1.0, 4.0, 1.0, 4.0, 1.0, 2.0} |> stats.statistics(_).variance |> math.close?(1.5, 6)");
    try testing.topTrue("{1.0, 2.0, 1.0, 4.0, 1.0, 4.0, 1.0, 2.0} |> stats.statistics(_).sample_variance |> math.close?(1.714285714285715, 15)");
    // Skewness result in revo current impl: 0.8164965809277258
    try testing.topTrue("{1.0, 2.0, 1.0, 4.0, 1.0, 4.0, 1.0, 2.0} |> stats.statistics(_).skewness |> math.close?(0.8164965809277261, 14)");
    try testing.topTrue("{1.0, 2.0, 1.0, 4.0, 1.0, 4.0, 1.0, 2.0} |> stats.statistics(_).sample_skewness |> math.close?(1.018350154434631, 15)");
    try testing.topTrue("{1.0, 2.0, 1.0, 4.0, 1.0, 4.0, 1.0, 2.0} |> stats.statistics(_).kurtosis |> math.close?(-1.0, 1)");
    // Sample kurtosis result in revo current impl: -0.6999999999999984
    try testing.topTrue("{1.0, 2.0, 1.0, 4.0, 1.0, 4.0, 1.0, 2.0} |> stats.statistics(_).sample_kurtosis |> math.close?(-0.7000000000000008, 14)");
    try testing.topTrue("stats.regression({1, 2, 3, 4, 5}, {2, 3, 5, 4, 6}).slope |> math.close?(0.9, 1)");
    try testing.topTrue("stats.regression({1, 2, 3, 4, 5}, {2, 3, 5, 4, 6}).intercept |> math.close?(1.3, 1)");
    try testing.topTrue("stats.regression({1, 2, 3, 4, 5}, {2, 3, 5, 4, 6}).correlation |> math.close?(0.9, 1)");
    try testing.topTrue("stats.regression({1, 2, 3, 4, 5}, {2, 3, 5, 4, 6}).covariance |> math.close?(1.8, 1)");
    try testing.topTrue("stats.regression({1, 2, 3, 4, 5}, {2, 3, 5, 4, 6}).sample_covariance |> math.close?(2.25, 1)");
}

// harmonic_mean(data, weights=None)
// Harmonic mean of data.

// median_low(data)
// Low median of data.

// median_high(data)
// High median of data.

// median_grouped(data, interval=1.0)
// Median (50th percentile) of grouped data.

// quantiles(data, n=4, method='exclusive')
// Divide data into intervals with equal probability.
