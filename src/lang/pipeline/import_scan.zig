const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;

pub const Fs = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    import_dir: ?[]const u8 = null,
    collections: []const revo.import_path.Collection = &.{},

    pub fn fromVm(vm: *VM) Fs {
        return .{
            .io = vm.runtime.io,
            .alloc = vm.runtime.alloc,
            .import_dir = vm.import_dir,
            .collections = vm.collections.items,
        };
    }
};
