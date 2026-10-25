const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;

pub const Fs = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    import_dir: ?[]const u8 = null,
    project_root: []const u8 = "",
    package_path: []const []const u8 = &.{},

    pub fn fromVm(vm: *VM) Fs {
        return .{
            .io = vm.runtime.io,
            .alloc = vm.runtime.alloc,
            .import_dir = vm.import_dir,
            .project_root = vm.project_root,
            .package_path = vm.package_path.items,
        };
    }
};

/// resolve module path matching runtime import resolution
pub fn resolveModuleFile(vm: *VM, name: []const u8) !?[]const u8 {
    return resolveModuleFileWithFs(Fs.fromVm(vm), name);
}

pub fn resolveModuleFileWithFs(fs: Fs, name: []const u8) !?[]const u8 {
    return revo.resolveImportFile(
        fs.io,
        fs.alloc,
        name,
        fs.import_dir,
        fs.project_root,
        fs.package_path,
    );
}
