const revo = @import("revo");
const std = @import("std");

const extension = revo.extension;
const VM = extension.VM;
const HostResult = extension.HostResult;

const flate = std.compress.flate;
const zstd = std.compress.zstd;
const lzma = std.compress.lzma;
const xz = std.compress.xz;

const Args = extension.ArgTypes;

pub const Impl = struct {
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
