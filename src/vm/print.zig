const std = @import("std");

const revo = @import("revo");
const style = revo.pretty.style;

const memory = @import("memory.zig");
const Data = memory.Data;

const color_reset = "\x1b[0m";
const color_accent = "\x1b[33m"; // numbers, atoms, array indices, table keys
const color_string = "\x1b[32m"; // strings
const color_brace = "\x1b[34m"; // table braces

// backstop against unbounded recursion
//   e.g. a __tostring/__display metamethod chain that keeps producing brand=new values forever
// . this alone doesnt catch true cycles gracefully
//      (it just bails after printing max_write_depth levels)
// , so it's paired with the ancestor-stack cycle detector below
// , which catches the common case (a table that contains itself) immediately and cheaply
threadlocal var write_depth: usize = 0;
const max_write_depth: usize = 200;

// detects genuine cycles
//   (a table that directly or indirectly contains itself)
// by tracking which tables are currently being printed
// , i.e. are ancestors of the value we're about to print
//
// . if we're asked to print a table that's already an active ancestor
// , we print "<circular>" instead of recursing into it again
//
// identity is tracked via the resolved pointer rather than the pool's internal id
// , so this doesn't need to know the id type
// . this is not a "seen anywhere" set
//   - the same table referenced from two unrelated
// fields is fine and will be printed twice
// ; only an actual ancestor-of-itself trips it

// sized off max_write_depth just to reuse one constant
// ; pushVisiting below bounds-checks against this array's actual length
// , so correctness doesn't depend on this size matching write_depth's cap
threadlocal var visiting: [max_write_depth]usize = undefined;
threadlocal var visiting_len: usize = 0;

fn isVisiting(addr: usize) bool {
    var i: usize = 0;
    while (i < visiting_len) : (i += 1) {
        if (visiting[i] == addr) return true;
    }
    return false;
}

// returns false if the stack full
// . bounds-checked independently of write_depth rather than assuming the two counters stay in lockstep
// ; they don't in every path
//   (writeTable can be entered directly
//   , without first passing through writeData's own depth check)
fn pushVisiting(addr: usize) bool {
    if (visiting_len >= visiting.len) return false;
    visiting[visiting_len] = addr;
    visiting_len += 1;
    return true;
}

fn popVisiting() void {
    visiting_len -= 1;
}

fn styledPrint(
    writer: *std.Io.Writer,
    mode: Data.RenderMode,
    color: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) anyerror!void {
    const colored = mode == .pretty;
    if (colored) try style(writer, color);
    try writer.print(fmt, args);
    if (colored) try style(writer, color_reset);
}

fn writeEscapedString(writer: *std.Io.Writer, s: []const u8) anyerror!void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            8 => try writer.writeAll("\\b"),
            12 => try writer.writeAll("\\f"),
            11 => try writer.writeAll("\\v"),
            0 => try writer.writeAll("\\0"),
            else => if (c < 32 or c >= 127) {
                const hex = "0123456789abcdef";
                try writer.writeAll("\\x");
                try writer.writeByte(hex[c >> 4]);
                try writer.writeByte(hex[c & 0xF]);
            } else {
                try writer.writeByte(c);
            },
        }
    }
    try writer.writeByte('"');
}

pub fn writeData(self: Data, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
    if (write_depth >= max_write_depth) {
        try writer.writeAll("<max-depth-exceeded>");
        return;
    }
    write_depth += 1;
    defer write_depth -= 1;

    const metamethod = switch (mode) {
        .display => try vm.getMetamethodByAtom(self, try vm.internAtom("__display")) orelse
            try vm.getMetamethodByAtom(self, revo.core_atoms.__tostring.atomId()),
        .debug, .pretty => try vm.getMetamethodByAtom(self, revo.core_atoms.__debug.atomId()),
    };
    if (metamethod) |mm| {
        if (mm.tag() != .function) return error.TypeError;
        return writeData(try vm.callFunctionParts(mm, null, &.{self}, null), writer, vm, mode);
    }

    switch (self.tag()) {
        .number => try styledPrint(writer, mode, color_accent, "{}", .{self.asNum().?}),
        .string => switch (mode) {
            .display => try writer.writeAll(vm.stringValue(self.asString().?)),
            .debug => try writeEscapedString(writer, vm.stringValue(self.asString().?)),
            .pretty => {
                try style(writer, color_string);
                try writeEscapedString(writer, vm.stringValue(self.asString().?));
                try style(writer, color_reset);
            },
        },
        .atom => {
            try styledPrint(writer, mode, color_accent, ":{s}", .{vm.stringValue(self.asAtom().?)});
        },
        .function => {
            const id = self.asFunction().?;
            const f = try vm.functions.get(id);
            switch (f.*) {
                .host => try writer.print("#fn@{}()/{}", .{ id, f.arity() }),
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
        .foreign => try writer.print("<foreign {*}>", .{self.asForeign().?}),
    }
}

fn writeTableKey(key: Data, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
    const colored = mode == .pretty;
    switch (key.tag()) {
        .atom => {
            if (colored) try style(writer, color_accent);
            try writer.writeAll(vm.stringValue(key.asAtom().?));
            if (colored) try style(writer, color_reset);
        },
        .string => {
            if (colored) try style(writer, color_string);
            try writeEscapedString(writer, vm.stringValue(key.asString().?));
            if (colored) try style(writer, color_reset);
        },
        else => try writeData(key, writer, vm, mode),
    }
}

pub fn writeTable(tbl: *revo.table.Table, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
    if (mode == .pretty) {
        try writePrettyTable(tbl, writer, vm, 0);
        return;
    }

    const addr = @intFromPtr(tbl);
    if (isVisiting(addr)) {
        try writer.writeAll("<circular>");
        return;
    }
    if (!pushVisiting(addr)) {
        try writer.writeAll("<max-depth-exceeded>");
        return;
    }
    defer popVisiting();

    if (tbl.array.items.len == 0 and tbl.hash.count == 0) {
        try writer.writeAll("{}");
        return;
    }

    try writer.writeAll("{ ");
    const hash_count = tbl.hash.count;
    const multi_line = mode == .debug and hash_count >= 2;
    var first = true;
    var array_left = tbl.array.items.len;
    var cur = tbl.cursor();

    while (cur.nextEntry()) |entry| {
        if (array_left > 0) {
            array_left -= 1;
            if (!first) try writer.writeAll(", ");
            first = false;

            try writeData(entry.value, writer, vm, mode);
        } else if (multi_line) {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\n  ");
            try writeTableKey(entry.key, writer, vm, mode);
            try writer.writeAll(" = ");

            try writeData(entry.value, writer, vm, mode);
            first = false;
        } else {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writeTableKey(entry.key, writer, vm, mode);
            try writer.writeAll(" = ");

            try writeData(entry.value, writer, vm, mode);
        }
    }

    if (multi_line) {
        try writer.writeAll("\n}");
    } else {
        try writer.writeAll(" }");
    }
}

fn writePrettyTable(tbl: *revo.table.Table, writer: *std.Io.Writer, vm: *revo.VM, indent_level: usize) anyerror!void {
    if (write_depth >= max_write_depth) {
        try writer.writeAll("<max-depth-exceeded>");
        return;
    }
    write_depth += 1;
    defer write_depth -= 1;

    const addr = @intFromPtr(tbl);
    if (isVisiting(addr)) {
        try writer.writeAll("<circular>");
        return;
    }
    if (!pushVisiting(addr)) {
        try writer.writeAll("<max-depth-exceeded>");
        return;
    }
    defer popVisiting();

    if (tbl.array.items.len == 0 and tbl.hash.count == 0) {
        try style(writer, color_brace);
        try writer.writeAll("{");
        try style(writer, color_reset);
        try style(writer, color_brace);
        try writer.writeAll("}");
        try style(writer, color_reset);
        return;
    }

    const indent = "  ";
    try style(writer, color_brace);
    try writer.writeAll("{");
    try style(writer, color_reset);
    try writer.writeAll("\n");

    if (tbl.array.items.len > 0) {
        var i: usize = 0;
        while (i < indent_level + 1) : (i += 1) {
            try writer.writeAll(indent);
        }
        var first = true;
        for (tbl.array.items) |val| {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writePrettyDataValue(val, writer, vm, indent_level + 1);
        }
        try writer.writeAll(",\n");
    }

    var hi: usize = 0;
    var hit = tbl.hash.orderedIterator();
    while (hit.next()) |entry| {
        var i: usize = 0;
        while (i < indent_level + 1) : (i += 1) {
            try writer.writeAll(indent);
        }
        try writeTableKey(entry.key, writer, vm, .pretty);
        try writer.writeAll(" = ");
        try writePrettyDataValue(entry.value, writer, vm, indent_level + 1);
        if (hi + 1 < tbl.hash.count) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
        hi += 1;
    }

    var j: usize = 0;
    while (j < indent_level) : (j += 1) {
        try writer.writeAll(indent);
    }
    try style(writer, color_brace);
    try writer.writeAll("}");
    try style(writer, color_reset);
}

fn writePrettyDataValue(val: Data, writer: *std.Io.Writer, vm: *revo.VM, indent_level: usize) anyerror!void {
    if (val.tag() == .table) {
        const tbl = vm.tables.get(val.asTable().?) catch {
            try writer.writeAll("<dead-table>");
            return;
        };
        try writePrettyTable(tbl, writer, vm, indent_level);
    } else {
        try writeData(val, writer, vm, .pretty);
    }
}
