const revo = @import("revo");
const std = @import("std");

const extension = revo.extension;
const VM = extension.VM;
const HostResult = extension.HostResult;

const Args = extension.ArgTypes;

pub const Impl = struct {
    pub fn encode(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer out.deinit();

        try std.base64.standard.Encoder.encodeWriter(&out.writer, str);
        return .data(try vm.adoptValueString(try out.toOwnedSlice()));
    }

    pub fn decode(vm: *VM, input: Args.string) !HostResult {
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

    pub fn url_encode(vm: *VM, input: Args.string) !HostResult {
        const str = vm.stringValue(@backingInt(input));
        var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer out.deinit();

        try std.base64.url_safe_no_pad.Encoder.encodeWriter(&out.writer, str);
        return .data(try vm.adoptValueString(try out.toOwnedSlice()));
    }

    pub fn url_decode(vm: *VM, input: Args.string) !HostResult {
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
};
