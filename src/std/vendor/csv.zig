// © Copyright 2024 Mikołaj Kuranowski
// SPDX-License-Identifier: MIT

//! Library for CSV (as per [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180)) reading and writing.
//!
//! Links: [GitHub](https://github.com/mkuranowski/zig-csv) | [Documentation](https://mkuranowski.github.io/zig-csv/)

const std = @import("std");

/// Terminator represents a record delimiter - either a specific octet, or the CR LF sequence.
pub const Terminator = union(enum) {
    octet: u8,
    crlf,
};

/// Dialect controls special characters used by `Reader` and `Writer`.
///
/// A default Dialect (`.{}`) is fully compatible with [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2).
pub const Dialect = struct {
    /// delimiter is the octet used to delimit fields within a single record.
    ///
    /// This corresponds to the [COMMA rule from RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2).
    delimiter: u8 = ',',

    /// quote is an octet used to enclose fields containing other special characters.
    /// Quotes within a quoted field must be escaped by another quote character.
    ///
    /// When set to `null`, quotes will not be treated specially by `Reader`,
    /// but `Writer` will use `"` when necessary.
    ///
    /// This corresponds to the [DQUOTE rule from RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2).
    quote: ?u8 = '"',

    /// terminator is an octet (or the CR LF sequence) used to terminate records.
    ///
    /// When set to `Terminator.crlf`, `Writer` will always terminate records by the CR LF sequence,
    /// but `Reader` will also accept sole CR or LF octets as record terminators.
    ///
    /// This corresponds to the [COMMA rule from RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2).
    terminator: Terminator = .crlf,

    /// bom controls the behavior for dealing with [UTF-8 Byte Order Mark](https://en.wikipedia.org/wiki/Byte_order_mark)
    /// (0xEF 0xBB 0xBF octet sequence) at the beginning of a file.
    ///
    /// When set to `null` (default), BOM (if it exists) will be discarded by `Reader`
    /// and not added by `Writer`.
    ///
    /// When set to `true`, BOM (if it exists) will be discarded by `Reader` and added by `Writer`.
    ///
    /// When set to `false`, BOM (if it exists) will be treated as part of the very first field
    /// of the file by `Reader`, and will not be added by `Writer`.
    bom: ?bool = null,
};

const State = enum {
    before_record,
    before_field,
    in_field,
    in_quoted_field,
    quote_in_quoted,
    eat_bom,
};

/// Parser parses [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2) CSV files.
///
/// The parser deviates from the standard in the following ways:
/// 1. Fields (TEXTDATA) may contain any bytes, as long as they are not COMMA, DQUOTE or CRLF.
/// 2. Fields can also be a concatenation of `escaped` and `non-escaped` data. This is done for
///    handling simplicity. Fields like `"foo"bar` are not treated as an error, but are parsed
///    as `foobar`.
/// 3. DQUOTE present in a `non-escaped` field is not treated as an error, rather the DQUOTE octet
///    is appended to the field. Encodings `"Foo ""Bar"" Baz"` and `Foo "Bar" Baz` are equivalent
///    and parse the same as the string literal `"Foo \"Bar\" Baz"`.
/// 4. Initial 0xEF 0xBB 0xBF (UTF-8 encoding of U+FEFF, the "byte order mark") may be consumed,
///    depending on the value of `Dialect.bom`.
/// 5. The values for COMMA, DQUOTE or CRLF rules can be customized; see `Dialect` for details.
pub const Reader = struct {
    r: *std.Io.Reader,
    d: Dialect,

    line_no: u32 = 1,
    eat_bom: bool = false,

    /// Creates a new Parser over the provided Reader. The Reader must be buffered,
    /// with a buffer length of at least 3 for all features to work.
    pub inline fn init(io_reader: *std.Io.Reader, dialect: Dialect) Reader {
        return .{
            .r = io_reader,
            .d = dialect,
            .eat_bom = dialect.bom != false,
        };
    }

    /// Parses a single row from the underlying file. Returns true if the row was successfully
    /// parsed and false on EOF. This function is designed to be called in a
    /// `while (try r.next(...))` loop.
    pub fn next(self: *Reader, record: *Record) !bool {
        record.line_no = self.line_no;
        record.clear();

        // Parse data until a record is fully parsed
        const state: State = if (self.eat_bom) .eat_bom else .before_record;
        sw: switch (state) {
            .before_record => {
                // Finish parsing altogether, or jump to .in_field or .in_quoted_field
                const b = try self.peekByte();
                if (b == null) {
                    return false; // no more data
                } else if (b == self.d.quote) {
                    self.toss(1);
                    continue :sw .in_quoted_field;
                } else {
                    continue :sw .in_field;
                }
            },

            .before_field => {
                // Jump to .in_field or .in_quoted_field
                const b = try self.peekByte();
                if (b == self.d.quote) {
                    self.toss(1);
                    continue :sw .in_quoted_field;
                } else {
                    continue :sw .in_field;
                }
            },

            .in_field => {
                // Advance record until delimiter or terminator
                const stop_octets: []const u8 = switch (self.d.terminator) {
                    .octet => |terminator| &.{ self.d.delimiter, terminator },
                    .crlf => &.{ self.d.delimiter, '\r', '\n' },
                };

                const r = try self.peekUntil(stop_octets);
                const data = r[0];
                const delim = r[1];

                // Stop parsing on EOF - report field as ready
                if (data.len == 0 and delim == null) {
                    try record.pushField();
                    return true;
                }

                // Push field data
                if (data.len > 0) {
                    try record.pushBytes(data);
                }

                // Skip read data
                self.toss(data.len + @intFromBool(delim != null));

                // Match with field delimiter
                if (delim == self.d.delimiter) {
                    try record.pushField();
                    continue :sw .before_field;
                }

                // Match with record terminator
                switch (self.d.terminator) {
                    .octet => |terminator| {
                        if (delim == terminator) {
                            try record.pushField();
                            return true;
                        }
                    },

                    .crlf => {
                        if (delim == '\r') {
                            try record.pushField();
                            try self.tossLf();
                            return true;
                        } else if (delim == '\n') {
                            try record.pushField();
                            return true;
                        }
                    },
                }

                continue :sw .in_field;
            },

            .in_quoted_field => {
                // Advance record until quote
                const r = try self.peekUntil(&.{self.d.quote.?});
                const data = r[0];
                const has_quote = r[1] != null;

                // Stop parsing on EOF - report field as ready
                if (data.len == 0 and !has_quote) {
                    try record.pushField();
                    return true;
                }

                // Push field data
                if (data.len > 0) {
                    try record.pushBytes(data);
                }

                // Skip read data
                self.toss(data.len + @intFromBool(has_quote));

                // Jump to .quote_in_quoted if seen a quote
                if (has_quote) continue :sw .quote_in_quoted;
                continue :sw .in_quoted_field;
            },

            .quote_in_quoted => {
                const b = try self.peekByte();
                if (b == null) {
                    // Stop parsing on EOF - report field as ready
                    return true;
                } else if (b == self.d.quote) {
                    // Escaped quote
                    try record.pushByte(b.?);
                    self.toss(1);
                    continue :sw .in_quoted_field;
                }
                // Jump to .in_field - end of quoted portion of the field
                continue :sw .in_field;
            },

            .eat_bom => {
                self.eat_bom = false;
                const b = try self.peek();
                if (std.mem.startsWith(u8, b, "\xEF\xBB\xBF")) {
                    self.r.toss(3); // BOM contains no newlines, we can bypass Reader.toss
                }
                continue :sw .before_record;
            },
        }

        unreachable;
    }

    /// Tosses `len` buffered bytes, advancing `self.line_no` by the number of tossed newlines.
    fn toss(self: *Reader, len: usize) void {
        const b = self.r.buffered()[0..len];
        self.line_no += @intCast(std.mem.count(u8, b, &.{'\n'}));
        self.r.toss(len);
    }

    /// Tosses the next byte if it's the newline, advancing `self.line_no` if that is the case.
    fn tossLf(self: *Reader) !void {
        if (try self.peekByte() == '\n') {
            self.r.toss(1);
            self.line_no += 1;
        }
    }

    /// Gets as much buffered data as possible, issuing only a single read if none is available.
    /// Returns `""` on EOF.
    fn peek(self: *Reader) error{ ReadFailed, EndOfStream }![]const u8 {
        return getFilledBuffer(self.r);
    }

    /// Gets the next buffered byte. Returns `null` on EOF.
    fn peekByte(self: *Reader) error{ ReadFailed, EndOfStream }!?u8 {
        return self.r.peekByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            inline else => |e| return e,
        };
    }

    /// Gets buffered data (from `peek()`) until the first instance of one of the provided delimiters.
    ///
    /// Returns:
    /// - `.{ "", null }` on EOF,
    /// - `.{ data, delimiter }` if any delimiter was found (note that data may be empty),
    /// - `.{ data, null }` otherwise.
    fn peekUntil(self: *Reader, delimiters: []const u8) error{ ReadFailed, EndOfStream }!struct { []const u8, ?u8 } {
        const b = try self.peek();
        if (std.mem.findAny(u8, b, delimiters)) |delim_idx| {
            return .{ b[0..delim_idx], b[delim_idx] };
        }
        return .{ b, null };
    }
};

fn getFilledBuffer(r: *std.Io.Reader) error{ ReadFailed, EndOfStream }![]const u8 {
    if (r.bufferedLen() > 0) {
        @branchHint(.likely);
        return r.buffered();
    }
    return getFilledBufferSlow(r);
}

fn getFilledBufferSlow(r: *std.Io.Reader) error{ ReadFailed, EndOfStream }![]const u8 {
    // Rebase to nothing buffered
    r.seek = 0;
    r.end = 0;

    // Request a read
    var bufs: [1][]u8 = .{""};
    _ = r.vtable.readVec(r, &bufs) catch |err| switch (err) {
        error.EndOfStream => return "",
        inline else => |e| return e,
    };

    // Ensure something was read
    const new_data = r.buffered();
    return new_data;
}

/// Writers writes [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2) CSV files.
///
/// The writer deviates from the standard in the following ways:
/// 1. Field (TEXTDATA) may contain any bytes, as long as they are not COMMA, DQUOTE or CRLF.
/// 2. The values for COMMA, DQUOTE or CRLF rules can be customized; see `Dialect` for details.
pub const Writer = struct {
    w: *std.Io.Writer,
    d: Dialect,
    needs_bom: bool = false,
    needs_comma: bool = false,
    bytes_to_escape: [4]u8,

    pub inline fn init(io_writer: *std.Io.Writer, dialect: Dialect) Writer {
        return .{
            .w = io_writer,
            .d = dialect,
            .needs_bom = dialect.bom orelse false,
            .bytes_to_escape = getBytesToEscape(dialect),
        };
    }

    fn getBytesToEscape(dialect: Dialect) [4]u8 {
        var to_escape: [4]u8 = undefined;
        to_escape[0] = dialect.delimiter;
        to_escape[1] = dialect.quote orelse '"';
        switch (dialect.terminator) {
            .octet => |terminator| {
                to_escape[2] = terminator;
                to_escape[3] = terminator;
            },

            .crlf => {
                to_escape[2] = '\r';
                to_escape[3] = '\n';
            },
        }
        return to_escape;
    }

    /// writeRecord writes a CSV record to the underlying writer.
    ///
    /// `record` can be either a slice, pointer-to-many or a tuple of []const u8
    /// (or anything which can automatically be coerced to []const u8);
    /// or simply a Record instance.
    ///
    /// It's forbidden to mix `writeRecord` and `writeField` calls to write a single record.
    /// If mixing both functions, a `writeRecord` can't follow a call to `writeField` -
    /// `terminateRecord` must be called first.
    pub fn writeRecord(self: *Writer, record: anytype) !void {
        switch (@typeInfo(@TypeOf(record))) {
            // Slice of fields
            .pointer => |ptr| {
                if (ptr.size == .Slice or ptr.size == .Many) {
                    for (record) |field| try self.writeField(field);
                    try self.terminateRecord();
                    return;
                }
            },

            // Tuple of fields
            .@"struct" => |str| {
                if (str.is_tuple) {
                    inline for (record) |field| try self.writeField(field);
                    try self.terminateRecord();
                    return;
                }
            },

            else => {},
        }

        if (@TypeOf(record) == Record) {
            for (0..record.len()) |i| try self.writeField(record.get(i));
            try self.terminateRecord();
            return;
        }

        @compileError(@typeName(@TypeOf(record)) ++ " can't be interpreted as a CSV record");
    }

    /// writeField writes a CSV field to the underlying writer.
    ///
    /// The caller must also call `terminateRecord` once all fields
    /// of the record have been written.
    pub fn writeField(self: *Writer, field: []const u8) !void {
        if (self.needs_bom) {
            @branchHint(.unlikely);
            try self.w.writeAll("\xEF\xBB\xBF");
            self.needs_bom = false;
        }

        if (self.needs_comma) try self.w.writeByte(self.d.delimiter);
        self.needs_comma = true;

        if (self.needsEscaping(field)) {
            const quote = self.d.quote orelse '"';

            var offset: usize = 0;
            try self.w.writeByte(quote);
            while (std.mem.findScalarPos(u8, field, offset, quote)) |i| {
                try self.w.writeAll(field[offset..i]);
                try self.w.writeAll(&.{ quote, quote });
                offset = i + 1;
            }
            try self.w.writeAll(field[offset..]);
            try self.w.writeByte(quote);
        } else {
            try self.w.writeAll(field);
        }
    }

    /// terminateRecord writes the record terminator to the underlying writer.
    pub fn terminateRecord(self: *Writer) !void {
        self.needs_comma = false;
        switch (self.d.terminator) {
            .octet => |terminator| try self.w.writeByte(terminator),
            .crlf => try self.w.writeAll("\r\n"),
        }
    }

    fn needsEscaping(self: Writer, field: []const u8) bool {
        return std.mem.findAny(u8, field, &self.bytes_to_escape) != null;
    }
};

/// Record represents a single record from a CSV file.
///
/// Even if get and getSafe functions return null-terminated strings, they make
/// no guarantee that no null bytes exist inside of the fields.
///
/// There recommended way to iterate over fields of a Record is:
///
/// ```zig
/// for (0..record.len()) |i| {
///     const field = record.get(i);
/// }
/// ```
pub const Record = struct {
    allocator: std.mem.Allocator,

    /// Line number of the record in the source file. If records spans multiple lines,
    /// it's the first line of the record.
    ///
    /// Line numbers are determined by the number of CRLF sequences (or sole CR/LF octets) seen
    /// in the provided reader, **not** the number of terminators.
    line_no: u32 = 0,

    /// Continuous buffer for all the fields concatenated together, separated by a null byte.
    buffer: std.ArrayList(u8) = .empty,

    /// Indices of the null bytes terminating the nth field.
    ends: std.ArrayList(usize) = .empty,

    pub inline fn init(allocator: std.mem.Allocator) Record {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Record) void {
        self.buffer.deinit(self.allocator);
        self.ends.deinit(self.allocator);
    }

    /// line returns the number of complete fields in this record
    pub inline fn len(self: Record) usize {
        return self.ends.items.len;
    }

    /// get returns the ith complete field
    pub fn get(self: Record, i: usize) [:0]u8 {
        const end = self.ends.items[i];
        const start = if (i > 0) self.ends.items[i - 1] + 1 else 0;
        return self.buffer.items[start..end :0];
    }

    /// get returns the ith complete field, or null if no valid field exists at the provided index.
    pub fn getSafe(self: Record, i: usize) ?[:0]u8 {
        if (i >= self.ends.items.len) return null;
        return self.get(i);
    }

    /// slice returns a slice over arrays holding the complete fields.
    ///
    /// The slice must be than deallocated with `allocator.free`
    pub fn slice(self: Record, allocator: std.mem.Allocator) ![][:0]u8 {
        var s = try allocator.alloc([:0]u8, self.ends.items.len);
        var start = 0;
        for (self.ends.items, 0..) |end, i| {
            s[i] = self.buffer.items[start..end :0];
            start = end + 1;
        }
        return s;
    }

    /// clear clears the record, retaining capacity in the existing slices.
    pub fn clear(self: *Record) void {
        self.buffer.clearRetainingCapacity();
        self.ends.clearRetainingCapacity();
    }

    /// pushField completes the field, built by previous calls to pushByte and pushBytes.
    fn pushField(self: *Record) !void {
        const end_idx = self.buffer.items.len;
        try self.buffer.append(self.allocator, 0);
        try self.ends.append(self.allocator, end_idx);
    }

    /// Adds a byte to the field-being-built, allocating that field if necessary.
    fn pushByte(self: *Record, b: u8) !void {
        try self.buffer.append(self.allocator, b);
    }

    /// Adds a byte to the field-being-built, allocating that field if necessary.
    fn pushBytes(self: *Record, b: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, b);
    }
};

test "csv.reading.basic" {
    const data = "pi,3.1416\r\nsqrt2,1.4142\r\nphi,1.618\r\ne,2.7183\r\n";
    var fixed_reader = std.Io.Reader.fixed(data);
    var r = Reader.init(&fixed_reader, .{});

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 1), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("pi", record.get(0));
    try std.testing.expectEqualStrings("3.1416", record.get(1));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 2), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("sqrt2", record.get(0));
    try std.testing.expectEqualStrings("1.4142", record.get(1));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 3), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("phi", record.get(0));
    try std.testing.expectEqualStrings("1.618", record.get(1));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 4), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("e", record.get(0));
    try std.testing.expectEqualStrings("2.7183", record.get(1));

    try std.testing.expect(!try r.next(&record));
}

test "csv.reading.with_quoted_fields" {
    const data =
        \\"hello","is it ""me""","you're
        \\looking for"
        \\"it's another
        \\record",with a newline inside,"but no ""trailing"" "one!
    ;
    var fixed_reader = std.Io.Reader.fixed(data);
    var r = Reader.init(&fixed_reader, .{});

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 1), record.line_no);
    try std.testing.expectEqual(@as(usize, 3), record.len());
    try std.testing.expectEqualStrings("hello", record.get(0));
    try std.testing.expectEqualStrings("is it \"me\"", record.get(1));
    try std.testing.expectEqualStrings("you're\nlooking for", record.get(2));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 3), record.line_no);
    try std.testing.expectEqual(@as(usize, 3), record.len());
    try std.testing.expectEqualStrings("it's another\nrecord", record.get(0));
    try std.testing.expectEqualStrings("with a newline inside", record.get(1));
    try std.testing.expectEqualStrings("but no \"trailing\" one!", record.get(2));

    try std.testing.expect(!try r.next(&record));
}

test "csv.reading.with_custom_dialect" {
    const data = "foo|bar#\"no quote handling|\"so this is another field#";
    var fixed_reader = std.Io.Reader.fixed(data);
    var r = Reader.init(
        &fixed_reader,
        .{
            .delimiter = '|',
            .quote = null,
            .terminator = .{ .octet = '#' },
        },
    );

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 1), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("foo", record.get(0));
    try std.testing.expectEqualStrings("bar", record.get(1));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 1), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("\"no quote handling", record.get(0));
    try std.testing.expectEqualStrings("\"so this is another field", record.get(1));
}

test "csv.reading.bom_true" {
    const data = "\xEF\xBB\xBFname,value";
    var fixed_reader = std.Io.Reader.fixed(data);
    var r = Reader.init(&fixed_reader, .{ .bom = true });

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqualStrings("name", record.get(0));
    try std.testing.expectEqualStrings("value", record.get(1));

    try std.testing.expect(!try r.next(&record));
}

test "csv.reading.bom_false" {
    const data = "\xEF\xBB\xBFname,value";
    var fixed_reader = std.Io.Reader.fixed(data);
    var r = Reader.init(&fixed_reader, .{ .bom = false });

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqualStrings("\xEF\xBB\xBFname", record.get(0));
    try std.testing.expectEqualStrings("value", record.get(1));

    try std.testing.expect(!try r.next(&record));
}

test "csv.writing.basic" {
    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();

    var w = Writer.init(&buffer.writer, .{});
    try w.writeRecord(.{ "foo", "bar", "baz" });

    try w.writeField("this field needs to be \"escaped\"");
    try w.writeField("and, this one\ntoo?");
    try w.writeField("but this one - 'no'");
    try w.terminateRecord();

    try std.testing.expectEqualStrings(
        "foo,bar,baz\r\n\"this field needs to be \"\"escaped\"\"\",\"and, this one\ntoo?\",but this one - 'no'\r\n",
        buffer.written(),
    );
}

test "csv.writing.bom" {
    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();

    var w = Writer.init(&buffer.writer, .{ .bom = true });
    try w.writeRecord(.{ "foo", "bar", "baz" });
    try w.writeRecord(.{ "spam", "eggs", "42" });

    try std.testing.expectEqualStrings(
        "\xEF\xBB\xBFfoo,bar,baz\r\nspam,eggs,42\r\n",
        buffer.written(),
    );
}

test "csv.writing.with_custom_dialect" {
    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();

    var w = Writer.init(
        &buffer.writer,
        .{
            .delimiter = '|',
            .quote = '\'',
            .terminator = .{ .octet = '#' },
        },
    );
    try w.writeRecord(.{ "foo", "bar", "baz" });
    try w.writeRecord(.{ "needs|escaping", "and'this#too", "\"but this\" - no" });

    try std.testing.expectEqualStrings(
        "foo|bar|baz#'needs|escaping'|'and''this#too'|\"but this\" - no#",
        buffer.written(),
    );
}

test "csv.writing.escaped_fields" {
    var buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buffer.deinit();

    var w = Writer.init(&buffer.writer, .{});
    try w.writeRecord(.{ "Foo \"Bar\" Baz", "\n,", "Two \"\" in row", "At end\"" });

    try std.testing.expectEqualStrings(
        "\"Foo \"\"Bar\"\" Baz\",\"\n,\",\"Two \"\"\"\" in row\",\"At end\"\"\"\r\n",
        buffer.written(),
    );
}
