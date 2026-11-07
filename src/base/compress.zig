const revo = @import("../root.zig");
const root = @import("root.zig");
const std = @import("std");

const VM = revo.VM;
const HostResult = root.host.HostResult;

const flate = std.compress.flate;
const zstd = std.compress.zstd;
const lzma = std.compress.lzma;
const xz = std.compress.xz;

const Args = root.host.ArgTypes;

pub const Impl = struct {
    pub fn base64_encode(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer out.deinit();
        try std.base64.standard.Encoder.encodeWriter(&out.writer, str);
        return .data(try vm.adoptValueString(try out.toOwnedSlice()));
    }

    pub fn base64_decode(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(str) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        const buf = try vm.runtime.alloc.alloc(u8, decoded_len);
        defer vm.runtime.alloc.free(buf);
        decoder.decode(buf, str) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.ownValueString(buf));
    }

    pub fn base64url_encode(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer out.deinit();
        try std.base64.url_safe_no_pad.Encoder.encodeWriter(&out.writer, str);
        return .data(try vm.adoptValueString(try out.toOwnedSlice()));
    }

    pub fn base64url_decode(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const decoded_len = decoder.calcSizeForSlice(str) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        const buf = try vm.runtime.alloc.alloc(u8, decoded_len);
        defer vm.runtime.alloc.free(buf);
        decoder.decode(buf, str) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.ownValueString(buf));
    }

    pub fn gzip_compress(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        const result = flateCompress(str, .gzip, vm.runtime.alloc) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.adoptValueString(result));
    }

    pub fn gzip_decompress(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        const result = flateDecompress(str, .gzip, vm.runtime.alloc) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.adoptValueString(result));
    }

    pub fn zlib_compress(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        const result = flateCompress(str, .zlib, vm.runtime.alloc) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.adoptValueString(result));
    }

    pub fn zlib_decompress(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        const result = flateDecompress(str, .zlib, vm.runtime.alloc) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.adoptValueString(result));
    }

    pub fn deflate(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        const result = flateCompress(str, .raw, vm.runtime.alloc) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.adoptValueString(result));
    }

    pub fn inflate(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        const result = flateDecompress(str, .raw, vm.runtime.alloc) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.adoptValueString(result));
    }

    pub fn zstd_decompress(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        var in = std.Io.Reader.fixed(str);
        var stream = zstd.Decompress.init(&in, &.{}, .{});
        const result = stream.reader.allocRemaining(vm.runtime.alloc, .limited(max_decompressed)) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.adoptValueString(result));
    }

    pub fn lzma_decompress(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        var in = std.Io.Reader.fixed(str);
        var buf: [8192]u8 = undefined;
        var stream = lzma.Decompress.initOptions(&in, vm.runtime.alloc, &buf, .{}, max_decompressed) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        defer stream.deinit();
        const result = stream.reader.allocRemaining(vm.runtime.alloc, .limited(max_decompressed)) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.adoptValueString(result));
    }

    pub fn xz_decompress(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        var in = std.Io.Reader.fixed(str);
        var buf: [8192]u8 = undefined;
        var stream = xz.Decompress.init(&in, vm.runtime.alloc, &buf) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        defer stream.deinit();
        const result = stream.reader.allocRemaining(vm.runtime.alloc, .limited(max_decompressed)) catch |err| {
            return HostResult.Err(vm, @errorName(err));
        };
        return HostResult.Ok(vm, try vm.adoptValueString(result));
    }
};

pub const impls = root.host.impls(Impl).val;

const max_decompressed: usize = 512 * 1024 * 1024;

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
    var decompressor = flate.Decompress.init(&in, container, &.{});
    return try decompressor.reader.allocRemaining(alloc, .limited(max_decompressed));
}
