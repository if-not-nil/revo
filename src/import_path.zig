//!
//! where import paths grow up to become files
//!
//! pls don't let this header drift
//!
//! `import` (static, resolved at compile time from the writing file)
//! ~ `./x`, `../x`  relative to the importing file's dir
//! ~ `name:x`       relative to the `name` collection's dir (`std:json`)
//! ~ `x`, `/abs/x`  errors, bare names stay free for packages
//!
//! `revo.load` (dynamic, the path is data)
//! ~ `name:x` like import, anything else from the cwd, absolute as-is
//!
//! `x` means `x.rv` or `x/init.rv`, both existing is an error
//! , `x.rv` written out means just that file
//! , dlls are never modules, they go through `revo.dload`
//! code with no file (`-e`, the repl) imports relative to the cwd
//!

const std = @import("std");

pub const Collection = struct {
    name: []const u8,
    dir: []const u8,
};

pub const Mode = enum { static, dynamic };

pub const Error = error{ OutOfMemory, UnknownCollection, BarePath, AbsolutePath, NativeLib };

/// what went wrong, for a diagnostic
pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownCollection => "unknown import collection",
        error.BarePath => "bare import paths are reserved, write `./x`",
        error.AbsolutePath => "absolute import paths aren't portable, use a collection or `revo.load`",
        error.NativeLib => "dlls aren't modules, load them with `revo.dload`",
        error.Ambiguous => "both `x.rv` and `x/init.rv` exist, rename one",
        error.FileNotFound => "module not found",
        else => @errorName(err),
    };
}

/// paths an import may name, in probe order
/// , normalized, absolute when the base is
pub const Candidates = struct {
    buf: [2][]u8 = undefined,
    len: usize = 0,

    pub fn paths(self: *const Candidates) []const []u8 {
        return self.buf[0..self.len];
    }

    pub fn deinit(self: Candidates, alloc: std.mem.Allocator) void {
        for (self.buf[0..self.len]) |p| alloc.free(p);
    }
};

/// `name` of `name:rest` path, else null
/// ; there's an exception for one-letter names so that C:\mod works
///   complain to bill gates not me
pub fn collectionName(raw: []const u8) ?[]const u8 {
    const colon = std.mem.findScalar(u8, raw, ':') orelse return null;
    return if (isCollectionName(raw[0..colon])) raw[0..colon] else null;
}

/// two or more of `[a-zA-Z0-9_]`
pub fn isCollectionName(name: []const u8) bool {
    if (name.len < 2) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

fn isRelative(raw: []const u8) bool {
    return std.mem.startsWith(u8, raw, "./") or std.mem.startsWith(u8, raw, "../") or
        std.mem.eql(u8, raw, ".") or std.mem.eql(u8, raw, "..");
}

fn isNativeLib(raw: []const u8) bool {
    const ext = std.Io.Dir.path.extension(raw);
    return std.mem.eql(u8, ext, ".so") or std.mem.eql(u8, ext, ".dylib") or std.mem.eql(u8, ext, ".dll");
}

/// `x.rv` and `x/init.rv`, or just `x.rv` when written out
pub fn candidates(
    alloc: std.mem.Allocator,
    raw: []const u8,
    importer_dir: []const u8,
    collections: []const Collection,
    mode: Mode,
) Error!Candidates {
    if (isNativeLib(raw)) return error.NativeLib;

    const base: ?[]const u8, const rest = if (collectionName(raw)) |name| blk: {
        for (collections) |c| {
            if (std.mem.eql(u8, c.name, name))
                break :blk .{ c.dir, raw[name.len + 1 ..] };
        }
        return error.UnknownCollection;
    } else if (std.Io.Dir.path.isAbsolute(raw)) blk: {
        if (mode == .static) return error.AbsolutePath;
        break :blk .{ null, raw };
    } else blk: {
        if (mode == .static and !isRelative(raw)) return error.BarePath;
        break :blk .{ importer_dir, raw };
    };

    const suffixes: []const []const u8 = if (std.mem.endsWith(u8, rest, ".rv"))
        &.{""}
    else
        &.{ ".rv", "/init.rv" };

    var out: Candidates = .{};
    errdefer out.deinit(alloc);

    for (suffixes) |suffix| {
        const tail = try std.mem.concat(alloc, u8, &.{ rest, suffix });
        defer alloc.free(tail);

        out.buf[out.len] = if (base) |b|
            try std.Io.Dir.path.resolveAlloc(alloc, &.{ b, tail })
        else
            try std.Io.Dir.path.resolveAlloc(alloc, &.{tail});
        out.len += 1;
    }

    return out;
}

/// realpath of the one candidate that's a file on disk
/// ; none is `FileNotFound`, two is `Ambiguous`
pub fn resolveFile(
    io: std.Io,
    alloc: std.mem.Allocator,
    raw: []const u8,
    importer_dir: []const u8,
    collections: []const Collection,
    mode: Mode,
) ![]const u8 {
    const cands = try candidates(alloc, raw, importer_dir, collections, mode);
    defer cands.deinit(alloc);

    var found: ?[]const u8 = null;
    errdefer if (found) |f| alloc.free(f);

    for (cands.paths()) |p| {
        const hit = try probeFile(io, alloc, p) orelse continue;
        if (found != null) {
            alloc.free(hit);
            return error.Ambiguous;
        }
        found = hit;
    }

    return found orelse error.FileNotFound;
}

/// realpath of `path`, if it's a file
fn probeFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const n = std.Io.Dir.cwd().realPathFile(io, path, &buf) catch |err| switch (err) {
        error.FileNotFound, error.IsDir, error.NotDir => return null,
        else => |e| return e,
    };

    // macos gives back the dir path instead of `IsDir`???????????
    const stat = std.Io.Dir.cwd().statFile(io, buf[0..n], .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    if (stat.kind == .directory) return null;

    return try alloc.dupe(u8, buf[0..n]);
}

/// std dir, like zig's lib dir
/// , found by walking up from the exe, trying `lib/revo/std` then `lib/std`; it has to hold `std.rv`
pub fn findStdDir(io: std.Io, alloc: std.mem.Allocator) ?[]u8 {
    const exe_dir = std.process.executableDirPathAlloc(io, alloc) catch return null;
    defer alloc.free(exe_dir);

    var cur: []const u8 = exe_dir;
    while (true) {
        for ([_][]const u8{ "lib/revo/std", "lib/std" }) |sub| {
            const dir = std.Io.Dir.path.join(alloc, &.{ cur, sub }) catch return null;
            const sentinel = std.Io.Dir.path.join(alloc, &.{ dir, "std.rv" }) catch {
                alloc.free(dir);
                return null;
            };
            defer alloc.free(sentinel);

            if (std.Io.Dir.cwd().statFile(io, sentinel, .{})) |_|
                return dir
            else |_|
                alloc.free(dir);
        }

        cur = std.Io.Dir.path.dirname(cur) orelse return null;
    }
}

test "candidates follow the importer and collections" {
    const alloc = std.testing.allocator;
    const cols = [_]Collection{.{ .name = "std", .dir = "/opt/revo/std" }};

    const rel = try candidates(alloc, "./x", "/src/app", &cols, .static);
    defer rel.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), rel.len);
    try std.testing.expectEqualStrings("/src/app/x.rv", rel.paths()[0]);
    try std.testing.expectEqualStrings("/src/app/x/init.rv", rel.paths()[1]);

    const up = try candidates(alloc, "../z", "/src/app", &cols, .static);
    defer up.deinit(alloc);
    try std.testing.expectEqualStrings("/src/z.rv", up.paths()[0]);

    const col = try candidates(alloc, "std:json", "/src/app", &cols, .static);
    defer col.deinit(alloc);
    try std.testing.expectEqualStrings("/opt/revo/std/json.rv", col.paths()[0]);

    const exact = try candidates(alloc, "./y.rv", "/src", &cols, .static);
    defer exact.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), exact.len);
    try std.testing.expectEqualStrings("/src/y.rv", exact.paths()[0]);

    try std.testing.expectError(error.UnknownCollection, candidates(alloc, "nope:x", "/src", &cols, .static));
    try std.testing.expect(collectionName("C:/x") == null);
}

test "static imports reject bare, absolute and dll paths, dynamic loads don't" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(error.BarePath, candidates(alloc, "x", "/src", &.{}, .static));
    try std.testing.expectError(error.AbsolutePath, candidates(alloc, "/lib/w", "/src", &.{}, .static));
    try std.testing.expectError(error.NativeLib, candidates(alloc, "./m.so", "/src", &.{}, .static));
    try std.testing.expectError(error.NativeLib, candidates(alloc, "./m.dylib", "/src", &.{}, .dynamic));

    const bare = try candidates(alloc, "lib/y", "/cwd", &.{}, .dynamic);
    defer bare.deinit(alloc);
    try std.testing.expectEqualStrings("/cwd/lib/y.rv", bare.paths()[0]);

    const abs = try candidates(alloc, "/lib/w", "/cwd", &.{}, .dynamic);
    defer abs.deinit(alloc);
    try std.testing.expectEqualStrings("/lib/w.rv", abs.paths()[0]);
}
