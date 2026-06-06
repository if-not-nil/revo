// this is the entrypoint for when you don't have an lsp built
const std = @import("std");
const revo = @import("revo");

pub fn runLsp(gpa: std.mem.Allocator, io: std.Io, mode: revo.lang.RunMode, project_root: []const u8) !void {
    _ = gpa;
    _ = io;
    _ = mode;
    _ = project_root;
    std.debug.print("lsp not available (build without -Dnolsp)\n", .{});
    std.process.exit(1);
}
