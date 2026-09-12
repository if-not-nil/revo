const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");

const Data = revo.Data;
const testing = revo.lang.testing;
const VM = revo.VM;
const HostResult = root.HostResult;

const csv = @import("./vendor/csv.zig");
const Reader = csv.Reader;
const Writer = csv.Writer;
const Record = csv.Record;
const Dialect = csv.Dialect;

const Ts = root.T;

pub const Impl = struct {
    pub fn encode(vm: *VM, data: Ts.any, raw_opts: Ts.table) !HostResult {
        const dialect = switch (try buildOpts(raw_opts, vm)) {
            .err => |e| return HostResult{ .err = e },
            .value => |v| v,
        };

        var buffer = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buffer.deinit();

        var writer = Writer.init(&buffer.writer, dialect);
        try writeCsvValue(data, vm, &writer, false);

        const slice = try buffer.toOwnedSlice();
        const result = try vm.adoptDataString(slice);
        return HostResult.Ok(vm, result);
    }

    pub fn decode(vm: *VM, source: Ts.string, raw_opts: Ts.table) !HostResult {
        const dialect = switch (try buildOpts(raw_opts, vm)) {
            .err => |e| return HostResult{ .err = e },
            .value => |v| v,
        };

        const str = vm.stringValue(@intFromEnum(source));
        var fixed_reader = std.Io.Reader.fixed(str);
        var reader = Reader.init(&fixed_reader, dialect);

        var record = Record.init(vm.runtime.alloc);
        defer record.deinit();

        var rows = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 8);
        defer rows.deinit(vm.runtime.alloc);

        while (try reader.next(&record)) {
            try rows.append(vm.runtime.alloc, try recordToData(record, vm));
        }

        return .data(try vm.tableOfSlice(rows.items));
    }
};

pub const impls = root.impls(Impl).val;

fn recordToData(record: Record, vm: *VM) anyerror!Data {
    var fields = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, record.len());
    defer fields.deinit(vm.runtime.alloc);
    for (0..record.len()) |i| {
        try fields.append(vm.runtime.alloc, try fieldToData(record.get(i), vm));
    }
    return vm.tableOfSlice(fields.items);
}

fn fieldToData(field: []const u8, vm: *VM) !Data {
    if (std.fmt.parseInt(i64, field, 10) catch null) |num| {
        return Data.new.num(num);
    } else if (std.fmt.parseFloat(f64, field) catch null) |float| {
        return Data.new.num(float);
    } else {
        return try vm.ownDataString(field);
    }
}

fn writeCsvValue(data: Data, vm: *VM, writer: *Writer, nested: bool) anyerror!void {
    switch (data.tag()) {
        .number => {
            try writeNum(data, vm, writer);
            if (!nested) try writer.terminateRecord();
        },
        .string => {
            try writeString(data, vm, writer);
            if (!nested) try writer.terminateRecord();
        },
        .atom => {
            const id = data.asAtom().?;
            const atom = vm.stringValue(id);
            try writer.writeField(atom);
            if (!nested) try writer.terminateRecord();
        },
        .table => {
            const table_id = data.asTable().?;
            const table = try vm.tables.get(table_id);
            for (table.array.items) |item| {
                try writeCsvValue(item, vm, writer, true);
            }
            if (nested) try writer.terminateRecord();
        },
        .function => return error.UnsupportedCsvValue,
        .foreign => return error.UnsupportedCsvValue,
    }
}

fn writeString(data: Data, vm: *VM, writer: *Writer) anyerror!void {
    try writer.writeField(vm.stringValue(data.asString().?));
}

fn writeNum(data: Data, vm: *VM, writer: *Writer) anyerror!void {
    const num = data.asNum().?;
    const str = try std.fmt.allocPrint(vm.runtime.alloc, "{d}", .{num});
    defer vm.runtime.alloc.free(str);
    try writer.writeField(str);
}

test "csv encode" {
    try testing.topString(
        \\ csv.encode({{"a", :b, 3}, {1.2, 0.3, "1.2"}, {1,2,3}}, {}):unwrap()
    , "a,b,3\r\n1.2,0.3,1.2\r\n1,2,3\r\n");
}

fn buildOpts(raw_opts: Ts.table, vm: *VM) !HostErrOr(Dialect) {
    var dialect = Dialect{};
    const opts = Data.new.table(@intFromEnum(raw_opts));
    if (vm.getField(opts, "delimiter")) |id| {
        if (id.asStr()) |delim_id| {
            const delim = vm.stringValue(delim_id);
            if (delim.len == 1) {
                dialect.delimiter = delim[0];
            } else {
                return .{ .err = HostResult.other("wants single character delimiter").err };
            }
        }
    }
    if (vm.getField(opts, "terminator")) |id| {
        if (id.asStr()) |terminator_id| {
            const terminator = vm.stringValue(terminator_id);
            if (terminator.len == 1) {
                dialect.terminator = .{ .octet = terminator[0] };
            } else {
                return .{ .err = HostResult.other("wants single character terminator").err };
            }
        }
    }
    if (vm.getField(opts, "quote")) |id| {
        if (id.asStr()) |quote_id| {
            const quote = vm.stringValue(quote_id);
            if (quote.len == 1) {
                dialect.quote = quote[0];
            } else {
                return .{ .err = HostResult.other("wants single character quote").err };
            }
        } else if (id.asAtom()) |quote_id| {
            if (quote_id == @intFromEnum(revo.core_atoms.nil)) {
                dialect.quote = null;
            }
        }
    }
    if (vm.getField(opts, "bom")) |id| {
        if (id.asAtom()) |bom_id| {
            if (bom_id == @intFromEnum(revo.core_atoms.true)) {
                dialect.bom = true;
            }
        } else {
            return .{ .err = HostResult.errType(@intFromEnum(raw_opts), ":true or :false", revo.std_lib.typeof(id, vm)).err };
        }
    }
    return .{ .value = dialect };
}

fn HostErrOr(comptime T: type) type {
    return union(enum) {
        value: T,
        err: revo.std_lib.HostErrPayload,
    };
}
