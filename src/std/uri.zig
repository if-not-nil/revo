const revo = @import("revo");
const std = @import("std");

const extension = revo.extension;
const Args = extension.ArgTypes;
const Value = extension.Value;
const testing = revo.lang.test_helpers;
const VM = extension.VM;
const HostResult = extension.HostResult;
const Uri = std.Uri;
const Component = std.Uri.Component;
const Table = revo.table.Table;

pub const Impl = struct {
    pub fn decode(vm: *VM, self: Args.string) !HostResult {
        const source = vm.stringValue(@backingInt(self));
        const uri = try std.Uri.parse(source);
        const root_id = try vm.tables.create();

        try parseScheme(&uri, root_id, vm);
        try parseComponent(uri.host, "host", root_id, vm);
        try parseComponent(uri.fragment, "fragment", root_id, vm);
        try parseComponent(uri.user, "user", root_id, vm);
        try parseComponent(uri.path, "path", root_id, vm);
        try parseQuery(&uri, root_id, vm);
        try parsePort(&uri, root_id, vm);

        return .Ok(vm, Value.new.table(root_id));
    }

    pub fn encode(vm: *VM, self: Args.table) !HostResult {
        var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer out.deinit();
        const val = Value.new.table(@backingInt(self));

        try writePart(val, "scheme", null, ":", &out.writer, vm);
        try writeAuthority(val, &out.writer, vm);
        try writePart(val, "user", null, "@", &out.writer, vm);
        try writePart(val, "host", null, null, &out.writer, vm);
        try writePort(val, &out.writer, vm);
        try writePart(val, "path", null, null, &out.writer, vm);
        try writeQuery(val, &out.writer, vm);
        try writePart(val, "fragment", "#", null, &out.writer, vm);

        const slice = try out.toOwnedSlice();
        const data = try vm.adoptValueString(slice);
        return .Ok(vm, data);
    }
};

fn writePart(val: Value, name: []const u8, prefix: ?[]const u8, postfix: ?[]const u8, w: *std.Io.Writer, vm: *VM) !void {
    if (vm.getField(val, name)) |part| {
        if (part.asString()) |sid| {
            if (prefix) |pre| try w.writeAll(pre);
            try w.writeAll(vm.stringValue(sid));
            if (postfix) |post| try w.writeAll(post);
        }
    }
}

fn writePort(val: Value, w: *std.Io.Writer, vm: *VM) !void {
    if (vm.getField(val, "port")) |port| {
        if (port.asNumOpt()) |num| {
            try w.writeAll(":");
            try w.print("{d}", .{num});
        }
    }
}

/// write `//` if a user or host exist to indicate the start of the authority
fn writeAuthority(val: Value, w: *std.Io.Writer, vm: *VM) !void {
    if (vm.getField(val, "user") != null or vm.getField(val, "host") != null) {
        try w.writeAll("//");
    }
}

fn writeQuery(val: Value, w: *std.Io.Writer, vm: *VM) !void {
    if (vm.getField(val, "query")) |query| {
        if (query.asTable()) |query_id| {
            const query_table = try vm.tables.get(query_id);
            try w.writeAll("?");
            var first = true;
            try writeArrayQuery(query_table, w, &first, vm);
            try writeHashQuery(query_table, w, &first, vm);
        }
    }
}

fn writeArrayQuery(table: *Table, w: *std.Io.Writer, first: *bool, vm: *VM) !void {
    for (table.array.items) |item| {
        const item_id = item.asStr();
        const num_id = item.asNumOpt();
        if ((item_id != null or num_id != null) and !first.*) {
            try w.writeAll("&");
        }
        if (num_id) |id| {
            try w.print("{d}", .{id});
            first.* = false;
        } else if (item_id) |id| {
            try w.writeAll(vm.stringValue(id));
            first.* = false;
        }
    }
}

fn writeHashQuery(table: *Table, w: *std.Io.Writer, first: *bool, vm: *VM) !void {
    var it = table.hash.orderedIterator();
    while (it.next()) |param| {
        if (param.key.asAtom()) |key| {
            if (param.value.asTable()) |param_id| {
                if (vm.tables.get(param_id)) |param_table| {
                    for (param_table.array.items) |item| {
                        if (!first.*) try w.writeAll("&");
                        try w.writeAll(vm.stringValue(key));
                        try w.writeAll("=");

                        if (item.asStr()) |val| {
                            try w.writeAll(vm.stringValue(val));
                        } else if (item.asNumOpt()) |val| {
                            try w.print("{d}", .{val});
                        }
                        first.* = false;
                    }
                } else |_| {}
            } else {
                if (!first.*) try w.writeAll("&");
                try w.writeAll(vm.stringValue(key));
                try w.writeAll("=");

                if (param.value.asStr()) |val| {
                    try w.writeAll(vm.stringValue(val));
                } else if (param.value.asNumOpt()) |val| {
                    try w.print("{d}", .{val});
                }
                first.* = false;
            }
        }
    }
}

fn parseScheme(uri: *const Uri, root_id: usize, vm: *VM) !void {
    try vm.putField(root_id, "scheme", try vm.ownValueString(uri.scheme));
}

fn parseParam(param: []const u8, query_id: usize, vm: *VM) !void {
    var query = try vm.tables.get(query_id);
    if (std.mem.findScalar(u8, param, '=')) |i| {
        const raw_key = param[0..i];
        const key = try vm.internAtom(raw_key);
        const val = param[i + 1 ..];
        const data = if (val.len == 0) Value.new.nil() else try parseValue(val, vm);
        if (query.getRawAtom(key, vm)) |existing| {
            // key exists, add to or create a table
            if (existing.asTable()) |id| {
                var table = try vm.tables.get(id);
                try table.push(vm.runtime.alloc, data);
            } else {
                const id = try vm.tables.create();
                var table = try vm.tables.get(id);

                try table.push(vm.runtime.alloc, existing);
                try table.push(vm.runtime.alloc, data);
                try query.putRawAtom(key, Value.new.table(id), vm);
            }
        } else {
            try query.putRawAtom(key, data, vm);
        }
    } else {
        try query.push(vm.runtime.alloc, try vm.ownValueString(param));
    }
}

fn parseValue(val: []const u8, vm: *VM) !Value {
    const num = std.fmt.parseFloat(f64, val) catch return try vm.ownValueString(val);
    return Value.new.num(num);
}

fn parseQuery(uri: *const Uri, root_id: usize, vm: *VM) !void {
    if (uri.query) |query| {
        // parse query parameters
        var params = std.mem.tokenizeScalar(u8, query.percent_encoded, '&');
        const table_id = try vm.tables.create();
        while (params.peek() != null) {
            const param = params.next().?;
            try parseParam(param, table_id, vm);
        }
        try vm.putField(root_id, "query", Value.new.table(table_id));
    }
}

fn parsePort(uri: *const Uri, root_id: usize, vm: *VM) !void {
    if (uri.port) |port| {
        try vm.putField(root_id, "port", Value.new.num(port));
    }
}

fn parseComponent(component: ?Component, name: []const u8, root_id: usize, vm: *VM) !void {
    if (component) |c| {
        const value = try vm.ownValueString(c.percent_encoded);
        try vm.putField(root_id, name, value);
    }
}

test "encode url" {
    var res = try testing.topResult(
        \\ {
        \\   scheme = "https",
        \\   host = "example.com",
        \\   fragment = "woah",
        \\   user = "username",
        \\   path = "/p/TRUE",
        \\   query = { "1", "2", chilling = "yeah", t = { "y", "n" } },
        \\   port = 67
        \\ }
    , null);
    defer res.deinit();

    // the dylib can't be loaded from here, so call the impl on the built table
    const out = try Impl.encode(&res.vm, @fromBackingInt(res.value.asTable().?));
    var it = (try res.vm.tables.get(out.ok.asTable().?)).cursor();
    try std.testing.expectEqual(Value.new.core(.ok), it.nextValue().?);

    const s = it.nextValue().?.asString().?;
    try std.testing.expectEqualStrings("https://username@example.com:67/p/TRUE?1&2&chilling=yeah&t=y&t=n#woah", res.vm.stringValue(s));
}
