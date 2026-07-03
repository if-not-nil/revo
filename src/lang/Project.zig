const std = @import("std");
const Workspace = @import("Workspace.zig");
const RunMode = @import("pipeline.zig").RunMode;
const FileId = @import("Workspace.zig").FileId;

pub const Project = @This();

mode: RunMode,
root: []const u8,

/// open a file in ws using this project's mode and root
pub fn open(self: Project, ws: *Workspace, name: []const u8, text: []const u8) !FileId {
    return ws.openWith(name, text, .{
        .mode = self.mode,
        .project_root = self.root,
    });
}

pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
    if (self.root.len > 0) allocator.free(self.root);
}

/// detect project mode by walking ancestors of name for lib.json / exe.json
pub fn detect(name: []const u8, io: std.Io, alloc: std.mem.Allocator) Project {
    const dir = std.fs.path.dirname(name) orelse return .{ .mode = .script, .root = "" };
    const abs_dir = std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, dir, alloc) catch return .{ .mode = .script, .root = "" };
    defer alloc.free(abs_dir);
    return walkForManifest(abs_dir, io, alloc);
}

/// detect from current working directory
pub fn detectFromCwd(io: std.Io, alloc: std.mem.Allocator) Project {
    const abs_cwd = std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, ".", alloc) catch return .{ .mode = .script, .root = "" };
    defer alloc.free(abs_cwd);
    return walkForManifest(abs_cwd, io, alloc);
}

fn walkForManifest(start: []const u8, io: std.Io, alloc: std.mem.Allocator) Project {
    var cur: []const u8 = start;
    while (true) {
        for (&[_][]const u8{ "lib.json", "exe.json" }) |manifest| {
            const joined = std.fs.path.join(alloc, &.{ cur, manifest }) catch continue;
            defer alloc.free(joined);
            _ = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, joined, .{}) catch continue;
            const root = alloc.dupe(u8, cur) catch return .{ .mode = .project, .root = "" };
            return .{ .mode = .project, .root = root };
        }
        const parent = std.fs.path.dirname(cur) orelse break;
        if (std.mem.eql(u8, parent, cur)) break;
        cur = parent;
    }
    return .{ .mode = .script, .root = "" };
}

const testing = std.testing;

test "detect on script file" {
    var p = Project.detect("/tmp/nonexistent/script.rv", testing.io, testing.allocator);
    defer p.deinit(testing.allocator);
    try testing.expect(p.mode == .script);
    try testing.expectEqualStrings("", p.root);
}

test "detect on project file" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(testing.io, .{ .sub_path = "lib.json", .data = "" });

    const abs_dir = try dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(abs_dir);
    const source_path = try std.fs.path.join(testing.allocator, &.{ abs_dir, "main.rv" });
    defer testing.allocator.free(source_path);

    var p = Project.detect(source_path, testing.io, testing.allocator);
    defer p.deinit(testing.allocator);
    try testing.expect(p.mode == .project);
    try testing.expectEqualStrings(abs_dir, p.root);
}

test "detect finds project manifest in ancestor and returns that dir" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(testing.io, .{ .sub_path = "exe.json", .data = "" });
    try dir.dir.createDir(testing.io, "apps", .default_dir);
    try dir.dir.createDir(testing.io, "apps/nested", .default_dir);

    const abs_dir = try dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(abs_dir);
    const source_path = try std.fs.path.join(testing.allocator, &.{ abs_dir, "apps", "nested", "main.rv" });
    defer testing.allocator.free(source_path);

    var p = Project.detect(source_path, testing.io, testing.allocator);
    defer p.deinit(testing.allocator);
    try testing.expect(p.mode == .project);
    try testing.expectEqualStrings(abs_dir, p.root);
}

test "detect ignores manifests outside source ancestors" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.createDir(testing.io, "project", .default_dir);
    try dir.dir.createDir(testing.io, "scripts", .default_dir);
    try dir.dir.writeFile(testing.io, .{ .sub_path = "project/lib.json", .data = "" });

    const abs_dir = try dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(abs_dir);
    const source_path = try std.fs.path.join(testing.allocator, &.{ abs_dir, "scripts", "main.rv" });
    defer testing.allocator.free(source_path);

    var p = Project.detect(source_path, testing.io, testing.allocator);
    defer p.deinit(testing.allocator);
    try testing.expect(p.mode == .script);
    try testing.expectEqualStrings("", p.root);
}
