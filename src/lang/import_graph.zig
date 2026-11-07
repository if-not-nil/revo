//!
//! every import one analysis resolved
//!
//! the checker fills it, the compiler, the lsp and the bundler read it
//! , so nothing resolves an import twice or scans for one by name
//!

const std = @import("std");

const cst = @import("cst.zig");

pub const Graph = struct {
    alloc: std.mem.Allocator,
    /// `.import` node of the analyzed file -> realpath
    sites: std.AutoHashMapUnmanaged(*const cst.CstNode, []const u8) = .empty,
    /// `const m = import("x")` in the analyzed file: `m` -> realpath
    bindings: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// realpath -> source for every module reached, deps before dependents
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// `importer ++ "\x00" ++ raw` -> realpath, every import any checker resolved
    /// , a bundled program resolves through these instead of the disk
    edges: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Graph) void {
        var it = self.sites.valueIterator();
        while (it.next()) |p| self.alloc.free(p.*);
        self.sites.deinit(self.alloc);

        var bit = self.bindings.iterator();
        while (bit.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.bindings.deinit(self.alloc);

        for (self.files.keys(), self.files.values()) |k, v| {
            self.alloc.free(k);
            self.alloc.free(v);
        }
        self.files.deinit(self.alloc);

        var eit = self.edges.iterator();
        while (eit.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.edges.deinit(self.alloc);
    }

    /// the realpath `raw` resolved to, written in `importer`
    pub fn edge(self: *const Graph, importer: []const u8, raw: []const u8) ?[]const u8 {
        var buf: [std.Io.Dir.max_path_bytes * 2]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ importer, raw }) catch return null;
        return self.edges.get(key);
    }

    pub fn addEdge(self: *Graph, importer: []const u8, raw: []const u8, path: []const u8) !void {
        const key = try std.fmt.allocPrint(self.alloc, "{s}\x00{s}", .{ importer, raw });
        errdefer self.alloc.free(key);
        const gop = try self.edges.getOrPut(self.alloc, key);
        if (gop.found_existing) {
            self.alloc.free(key);
            return;
        }

        gop.value_ptr.* = self.alloc.dupe(u8, path) catch |err| {
            self.edges.removeByPtr(gop.key_ptr);
            return err;
        };
    }

    pub fn addSite(self: *Graph, node: *const cst.CstNode, path: []const u8) !void {
        const gop = try self.sites.getOrPut(self.alloc, node);
        if (gop.found_existing) return;
        gop.value_ptr.* = try self.alloc.dupe(u8, path);
    }

    pub fn addBinding(self: *Graph, name: []const u8, path: []const u8) !void {
        const owned = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned);
        const gop = try self.bindings.getOrPut(self.alloc, name);
        if (gop.found_existing) {
            self.alloc.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.alloc.dupe(u8, name) catch |err| {
                self.bindings.removeByPtr(gop.key_ptr);
                return err;
            };
        }

        gop.value_ptr.* = owned;
    }

    pub fn addFile(self: *Graph, path: []const u8, source: []const u8) !void {
        if (self.files.contains(path)) return;
        const key = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(key);
        const text = try self.alloc.dupe(u8, source);
        errdefer self.alloc.free(text);

        try self.files.put(self.alloc, key, text);
    }
};
