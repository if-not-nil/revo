const std = @import("std");
const revo = @import("revo");
const memory = @import("memory.zig");
const Data = memory.Data;

pub fn writeData(self: Data, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
    if (mode == .debug) {
        if (try vm.getMetamethod(self, "__debug")) |mm| {
            const result = if (mm.isFunction()) try vm.callFunction(mm, &.{self}) else return error.TypeError;
            if (result.asString()) |id| {
                try writer.writeAll(vm.stringValue(id));
                return;
            }
            return error.TypeError;
        }
    }

    switch (self.tag()) {
        .number => try writer.print("{}", .{self.asNumber().?}),
        .string => switch (mode) {
            .display => try writer.writeAll(vm.stringValue(self.asString().?)),
            .debug => try writer.print("\"{s}\"", .{vm.stringValue(self.asString().?)}),
        },
        .atom => try writer.print(":{s}", .{vm.atomName(self.asAtom().?)}),
        .function => {
            const id = self.asFunction().?;
            const f = try vm.functions.get(id);
            switch (f.*) {
                .native => try writer.print("#fn(){}/{}", .{ id, f.arity() }),
                .c_function => |cf| try writer.print("${s}@{}()/{}", .{ cf.name, id, f.arity() }),
                .closure => try writer.print("{s}()/{d}", .{ f.name(), f.arity() }),
            }
        },
        .table => {
            const tbl = vm.tables.get(self.asTable().?) catch {
                try writer.writeAll("<dead-table>");
                return;
            };
            tbl.write(writer, vm, mode) catch try writer.writeAll("<table-unprintable>");
        },
        .tuple => {
            const tup = vm.tuples.get(self.asTuple().?) catch {
                try writer.writeAll("<dead-tuple>");
                return;
            };
            tup.write(writer, vm, mode) catch try writer.writeAll("<tuple-unprintable>");
        },
        .struct_val => {
            const instance_id = self.asStructVal().?;
            const instance = vm.struct_instances.get(instance_id) catch {
                try writer.writeAll("<dead-struct>");
                return;
            };
            const desc = vm.struct_types.getType(instance.type_id) orelse {
                try writer.writeAll("<unknown-struct>");
                return;
            };
            try writer.writeAll(desc.name);
            try writer.writeAll("{ ");
            for (desc.fields, 0..) |f, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.writeAll(vm.atomName(f.name_atom));
                try writer.writeAll(" = ");
                try writeData(instance.fields[i], writer, vm, mode);
            }
            try writer.writeAll(" }");
        },
        .struct_type => {
            const type_id = self.asStructType().?;
            const desc = vm.struct_types.getType(type_id) orelse {
                try writer.writeAll("<unknown-type>");
                return;
            };
            try writer.writeAll("#");
            try writer.writeAll(desc.name);
        },
        .module => {
            const ns_id = self.asNamespace().?;
            const ns = vm.modules.get(ns_id) catch {
                try writer.writeAll("<dead-module>");
                return;
            };
            const exports = vm.tables.get(ns.exports) catch {
                try writer.writeAll("<dead-module-exports>");
                return;
            };
            if (mode == .debug) {
                try writer.print("#ns<{s}> ", .{ns.path});
            }
            exports.write(writer, vm, mode) catch try writer.writeAll("<module-unprintable>");
        },
    }
}

pub fn writeTuple(t: *revo.tuple.Tuple, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
    try writer.writeAll("(");
    for (t.items, 0..) |item, i| {
        if (i != 0) try writer.writeAll(", ");
        try writeData(item, writer, vm, mode);
    }
    if (t.items.len == 1) try writer.writeAll(",");
    try writer.writeAll(")");
}

pub fn writeTable(tbl: *revo.table.Table, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
    try writer.writeAll("{ ");
    const should_write_idx = tbl.hash_entries.count() != 0;
    for (tbl.array.items, 0..) |val, idx| {
        if (should_write_idx) {
            try writeData(Data.new.num(idx), writer, vm, mode);
            try writer.writeAll(": ");
        }
        try writeData(val, writer, vm, mode);
        try writer.writeAll(", ");
    }
    for (tbl.hash_order.items) |key| {
        const val = tbl.hash_entries.get(key) orelse continue;
        if (should_write_idx) {
            try writeData(key, writer, vm, mode);
            try writer.writeAll(": ");
        }
        try writeData(val, writer, vm, mode);
        try writer.writeAll(", ");
    }
    try writer.writeAll("}");
}
