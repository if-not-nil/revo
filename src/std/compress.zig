const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;

const flate = std.compress.flate;
const zstd = std.compress.zstd;
const lzma = std.compress.lzma;
const xz = std.compress.xz;

pub const specs: []const api.FnSpec = &.{
    .{
        .name = "base64_encode",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "string",
        .doc = "encodes data as standard base64 with padding",
        .f = root.define(&.{.string}, base64Encode),
    },
    .{
        .name = "base64_decode",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "decodes standard base64 string",
        .f = root.define(&.{.string}, base64Decode),
    },
    .{
        .name = "base64url_encode",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "string",
        .doc = "encodes data as url-safe base64 without padding",
        .f = root.define(&.{.string}, base64UrlEncode),
    },
    .{
        .name = "base64url_decode",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "decodes url-safe base64 string",
        .f = root.define(&.{.string}, base64UrlDecode),
    },
    .{
        .name = "gzip_compress",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "compresses data using gzip format",
        .f = root.define(&.{.string}, gzipCompress),
    },
    .{
        .name = "gzip_decompress",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "decompresses gzip data",
        .f = root.define(&.{.string}, gzipDecompress),
    },
    .{
        .name = "zlib_compress",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "compresses data using zlib format",
        .f = root.define(&.{.string}, zlibCompress),
    },
    .{
        .name = "zlib_decompress",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "decompresses zlib data",
        .f = root.define(&.{.string}, zlibDecompress),
    },
    .{
        .name = "deflate",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "compresses data using raw deflate",
        .f = root.define(&.{.string}, deflateCompress),
    },
    .{
        .name = "inflate",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "decompresses raw deflate data",
        .f = root.define(&.{.string}, inflateDecompress),
    },
    .{
        .name = "zstd_decompress",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "decompresses zstd data",
        .f = root.define(&.{.string}, zstdDecompressFn),
    },
    .{
        .name = "lzma_decompress",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "decompresses lzma data",
        .f = root.define(&.{.string}, lzmaDecompressFn),
    },
    .{
        .name = "xz_decompress",
        .placements = &.{api.mod("compress")},
        .params = &.{.{ "data", "string" }},
        .ret = "!string",
        .doc = "decompresses xz data",
        .f = root.define(&.{.string}, xzDecompressFn),
    },
};

fn resultErr(vm: *VM, message: []const u8) !NativeResult {
    return root.resultTuple(vm, .err, try vm.ownDataString(message));
}

// -- [base64] ----------------------------------------------------------------

fn base64Encode(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    try std.base64.standard.Encoder.encodeWriter(&out.writer, input);
    return .okData(try vm.adoptDataString(try out.toOwnedSlice()));
}

fn base64Decode(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(input) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    const buf = try vm.runtime.alloc.alloc(u8, decoded_len);
    defer vm.runtime.alloc.free(buf);
    decoder.decode(buf, input) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.ownDataString(buf));
}

fn base64UrlEncode(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    try std.base64.url_safe_no_pad.Encoder.encodeWriter(&out.writer, input);
    return .okData(try vm.adoptDataString(try out.toOwnedSlice()));
}

fn base64UrlDecode(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(input) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    const buf = try vm.runtime.alloc.alloc(u8, decoded_len);
    defer vm.runtime.alloc.free(buf);
    decoder.decode(buf, input) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.ownDataString(buf));
}

// -- [flate compress] --------------------------------------------------------

fn flateCompress(input: []const u8, container: flate.Container, alloc: std.mem.Allocator) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(alloc, 256);
    defer out.deinit();
    var buffer: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&out.writer, &buffer, container, .default);
    try compressor.writer.writeAll(input);
    try compressor.finish();
    return out.toOwnedSlice();
}

fn flateDecompress(input: []const u8, container: flate.Container, alloc: std.mem.Allocator) ![]u8 {
    var in = std.Io.Reader.fixed(input);
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    var decompressor = flate.Decompress.init(&in, container, &.{});
    _ = try decompressor.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

fn gzipCompress(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    const result = flateCompress(input, .gzip, vm.runtime.alloc) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.adoptDataString(result));
}

fn gzipDecompress(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    const result = flateDecompress(input, .gzip, vm.runtime.alloc) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.adoptDataString(result));
}

fn zlibCompress(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    const result = flateCompress(input, .zlib, vm.runtime.alloc) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.adoptDataString(result));
}

fn zlibDecompress(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    const result = flateDecompress(input, .zlib, vm.runtime.alloc) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.adoptDataString(result));
}

fn deflateCompress(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    const result = flateCompress(input, .raw, vm.runtime.alloc) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.adoptDataString(result));
}

fn inflateDecompress(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    const result = flateDecompress(input, .raw, vm.runtime.alloc) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.adoptDataString(result));
}

// -- [zstd] ------------------------------------------------------------------

fn zstdDecompressFn(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    var in = std.Io.Reader.fixed(input);
    var stream = zstd.Decompress.init(&in, &.{}, .{});
    _ = stream.reader.streamRemaining(&out.writer) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.adoptDataString(try out.toOwnedSlice()));
}

// -- [lzma] ------------------------------------------------------------------

fn lzmaDecompressFn(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    var in = std.Io.Reader.fixed(input);
    var buf: [8192]u8 = undefined;
    var stream = lzma.Decompress.initOptions(&in, vm.runtime.alloc, &buf, .{}, std.math.maxInt(usize)) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    defer stream.deinit();
    _ = stream.reader.streamRemaining(&out.writer) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.adoptDataString(try out.toOwnedSlice()));
}

// -- [xz] --------------------------------------------------------------------

fn xzDecompressFn(args: []const Data, vm: *VM) !NativeResult {
    const input = vm.stringValue(args[0].asString().?);
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    var in = std.Io.Reader.fixed(input);
    var buf: [8192]u8 = undefined;
    var stream = xz.Decompress.init(&in, vm.runtime.alloc, &buf) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    defer stream.deinit();
    _ = stream.reader.streamRemaining(&out.writer) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    return root.resultTuple(vm, .ok, try vm.adoptDataString(try out.toOwnedSlice()));
}
