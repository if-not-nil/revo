const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");

const Ts = root.T;
const Data = revo.Data;
const testing = revo.lang.testing;
const VM = revo.VM;
const HostResult = root.HostResult;
const Uri = std.Uri;
const Component = std.Uri.Component;
const Table = revo.table.Table;

pub const Impl = struct {
    pub fn decode(vm: *VM, self: Ts.any) !HostResult {
        const source = vm.stringValue(self.asString().?);
        const uri = try std.Uri.parse(source);
        const root_id = try vm.tables.create();

        try parseScheme(&uri, root_id, vm);
        try parseComponent(uri.host, "host", root_id, vm);
        try parseComponent(uri.fragment, "fragment", root_id, vm);
        try parseComponent(uri.user, "user", root_id, vm);
        try parseComponent(uri.path, "path", root_id, vm);
        try parseQuery(&uri, root_id, vm);
        try parsePort(&uri, root_id, vm);

        return .data(Data.new.table(root_id));
    }

    pub fn encode(vm: *VM, self: Ts.table) !HostResult {
        var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer out.deinit();
        const val = Data.new.table(@intFromEnum(self));

        try writePart(val, "scheme", null, ":", &out.writer, vm);
        try writeAuthority(val, &out.writer, vm);
        try writePart(val, "user", null, "@", &out.writer, vm);
        try writePart(val, "host", null, null, &out.writer, vm);
        try writePort(val, &out.writer, vm);
        try writePart(val, "path", null, null, &out.writer, vm);
        try writeQuery(val, &out.writer, vm);
        try writePart(val, "fragment", "#", null, &out.writer, vm);

        const slice = try out.toOwnedSlice();
        const data = try vm.adoptDataString(slice);
        return HostResult.Ok(vm, data);
    }
};

pub const impls: []const api.Impl = root.impls(Impl).val;

fn writePart(val: Data, name: []const u8, prefix: ?[]const u8, postfix: ?[]const u8, w: *std.Io.Writer, vm: *VM) !void {
    if (vm.getField(val, name)) |part| {
        if (part.asString()) |sid| {
            if (prefix) |pre| try w.writeAll(pre);
            try w.writeAll(vm.stringValue(sid));
            if (postfix) |post| try w.writeAll(post);
        }
    }
}

fn writePort(val: Data, w: *std.Io.Writer, vm: *VM) !void {
    if (vm.getField(val, "port")) |port| {
        if (port.asNum()) |num| {
            try w.writeAll(":");
            try w.print("{d}", .{num});
        }
    }
}

/// write `//` if a user or host exist to indicate the start of the authority
fn writeAuthority(val: Data, w: *std.Io.Writer, vm: *VM) !void {
    if (vm.getField(val, "user") != null or vm.getField(val, "host") != null) {
        try w.writeAll("//");
    }
}

fn writeQuery(val: Data, w: *std.Io.Writer, vm: *VM) !void {
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
        const num_id = item.asNum();
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
                        } else if (item.asNum()) |val| {
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
                } else if (param.value.asNum()) |val| {
                    try w.print("{d}", .{val});
                }
                first.* = false;
            }
        }
    }
}

fn parseScheme(uri: *const Uri, root_id: usize, vm: *VM) !void {
    try vm.putField(root_id, "scheme", try vm.ownDataString(uri.scheme));
}

fn parseParam(param: []const u8, query_id: usize, vm: *VM) !void {
    var query = try vm.tables.get(query_id);
    if (std.mem.indexOfScalar(u8, param, '=')) |i| {
        const raw_key = param[0..i];
        const key = try vm.internAtom(raw_key);
        const val = param[i + 1 ..];
        const data = if (val.len == 0) Data.new.nil() else try valData(val, vm);
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
                try query.putRawAtom(key, Data.new.table(id), vm);
            }
        } else {
            try query.putRawAtom(key, data, vm);
        }
    } else {
        try query.push(vm.runtime.alloc, try vm.ownDataString(param));
    }
}

fn valData(val: []const u8, vm: *VM) !Data {
    const num = std.fmt.parseFloat(f64, val) catch return try vm.ownDataString(val);
    return Data.new.num(num);
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
        try vm.putField(root_id, "query", Data.new.table(table_id));
    }
}

fn parsePort(uri: *const Uri, root_id: usize, vm: *VM) !void {
    if (uri.port) |port| {
        try vm.putField(root_id, "port", Data.new.num(port));
    }
}

fn parseComponent(component: ?Component, name: []const u8, root_id: usize, vm: *VM) !void {
    if (component) |c| {
        const value = try vm.ownDataString(c.percent_encoded);
        try vm.putField(root_id, name, value);
    }
}

test "encode url" {
    const src =
        \\ uri.encode({
        \\   scheme = "https",
        \\   host = "example.com",
        \\   fragment = "woah",
        \\   user = "username",
        \\   path = "/p/TRUE",
        \\   query = { "1", "2", chilling = "yeah", t = { "y", "n" } },
        \\   port = 67
        \\ })?
    ;
    try testing.topString(src, "https://username@example.com:67/p/TRUE?1&2&chilling=yeah&t=y&t=n#woah");
}
