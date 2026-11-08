const revo = @import("revo");
const std = @import("std");

const extension = revo.extension;
const Value = extension.Value;
const testing = revo.lang.test_helpers;
const VM = extension.VM;
const HostResult = extension.HostResult;

const csv = @import("./vendor/csv.zig");
const Reader = csv.Reader;
const Writer = csv.Writer;
const Record = csv.Record;
const Dialect = csv.Dialect;

const Args = extension.ArgTypes;

pub const Impl = struct {
    pub fn encode(vm: *VM, data: Args.any, raw_opts: Args.table_sentinel) !HostResult {
        const dialect = switch (try buildOpts(raw_opts.value, vm)) {
            .err => |e| return HostResult{ .err = e },
            .value => |v| v,
        };

        var buffer = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buffer.deinit();

        var writer = Writer.init(&buffer.writer, dialect);
        try writeCsvValue(data, vm, &writer, false);

        const slice = try buffer.toOwnedSlice();
        const result = try vm.adoptValueString(slice);
        return HostResult.Ok(vm, result);
    }

    pub fn decode(vm: *VM, source: Args.string, raw_opts: Args.table_sentinel) !HostResult {
        const dialect = switch (try buildOpts(raw_opts.value, vm)) {
            .err => |e| return HostResult{ .err = e },
            .value => |v| v,
        };

        const str = vm.stringValue(@backingInt(source));
        var fixed_reader = std.Io.Reader.fixed(str);
        var reader = Reader.init(&fixed_reader, dialect);

        var record = Record.init(vm.runtime.alloc);
        defer record.deinit();

        var rows = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, 8);
        defer rows.deinit(vm.runtime.alloc);

        while (try reader.next(&record)) {
            try rows.append(vm.runtime.alloc, try recordToValue(record, vm));
        }

        return .data(try vm.tableOfSlice(rows.items));
    }
};

fn recordToValue(record: Record, vm: *VM) anyerror!Value {
    var fields = try std.ArrayList(Value).initCapacity(vm.runtime.alloc, record.len());
    defer fields.deinit(vm.runtime.alloc);
    for (0..record.len()) |i| {
        try fields.append(vm.runtime.alloc, try fieldToValue(record.get(i), vm));
    }
    return vm.tableOfSlice(fields.items);
}

fn fieldToValue(field: []const u8, vm: *VM) !Value {
    if (std.fmt.parseInt(i64, field, 10) catch null) |num| {
        return Value.new.num(num);
    } else if (std.fmt.parseFloat(f64, field) catch null) |float| {
        return Value.new.num(float);
    } else {
        return try vm.ownValueString(field);
    }
}

fn writeCsvValue(data: Value, vm: *VM, writer: *Writer, nested: bool) anyerror!void {
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
        .@"opaque" => return error.UnsupportedCsvValue,
        .resource => return error.UnsupportedCsvValue,
    }
}

fn writeString(data: Value, vm: *VM, writer: *Writer) anyerror!void {
    try writer.writeField(vm.stringValue(data.asString().?));
}

fn writeNum(data: Value, vm: *VM, writer: *Writer) anyerror!void {
    const num = data.asNumOpt().?;
    const str = try vm.runtime.alloc.print("{d}", .{num});
    defer vm.runtime.alloc.free(str);
    try writer.writeField(str);
}

test "csv encode" {
    var res = try testing.topResult(
        \\ {{"a", :b, 3}, {1.2, 0.3, "1.2"}, {1,2,3}}
    , null);
    defer res.deinit();

    // the dylib can't be loaded from here, so call the impl on the built table
    const opts: Args.table_sentinel = .{ .value = @fromBackingInt(try res.vm.tables.create()) };
    const out = try Impl.encode(&res.vm, res.value, opts);
    var it = (try res.vm.tables.get(out.ok.asTable().?)).cursor();
    try std.testing.expectEqual(Value.new.core(.ok), it.nextValue().?);

    const s = it.nextValue().?.asString().?;
    try std.testing.expectEqualStrings("a,b,3\r\n1.2,0.3,1.2\r\n1,2,3\r\n", res.vm.stringValue(s));
}

fn buildOpts(raw_opts: Args.table, vm: *VM) !HostErrOr(Dialect) {
    var dialect = Dialect{};
    const opts = Value.new.table(@backingInt(raw_opts));
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
            if (quote_id == @backingInt(revo.CoreAtoms.nil)) {
                dialect.quote = null;
            }
        }
    }
    if (vm.getField(opts, "bom")) |id| {
        if (id.asAtom()) |bom_id| {
            if (bom_id == @backingInt(revo.CoreAtoms.true)) {
                dialect.bom = true;
            }
        } else {
            return .{ .err = HostResult.errType(@backingInt(raw_opts), ":true or :false", revo.base.typeof(id, vm)).err };
        }
    }
    return .{ .value = dialect };
}

fn HostErrOr(comptime T: type) type {
    return union(enum) {
        value: T,
        err: revo.base.host.HostErrPayload,
    };
}
