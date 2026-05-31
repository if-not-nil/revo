const std = @import("std");

const revo = @import("revo");
const lang = @import("./root.zig");
const VM = revo.VM;

pub const FileId = u32;

pub const Snapshot = struct {
    id: FileId,
    version: u32,
    name: []const u8,
    text: []const u8,
};

const FileEntry = struct {
    id: FileId,
    version: u32,
    name: []u8,
    text: []u8,
};

const CacheEntry = struct {
    version: u32,
    opts: lang.BuildOptions,
    artifact: lang.Artifact,
};

pub const Workspace = struct {
    alloc: std.mem.Allocator,
    vm: *VM,
    files: std.ArrayList(FileEntry),
    file_index: std.AutoHashMap(FileId, usize),
    file_names: std.StringHashMap(FileId),
    cache: std.AutoHashMap(FileId, CacheEntry),
    next_file_id: FileId = 1,

    pub fn init(vm: *VM, alloc: std.mem.Allocator) !Workspace {
        return .{
            .alloc = alloc,
            .vm = vm,
            .files = try std.ArrayList(FileEntry).initCapacity(alloc, 8),
            .file_index = std.AutoHashMap(FileId, usize).init(alloc),
            .file_names = std.StringHashMap(FileId).init(alloc),
            .cache = std.AutoHashMap(FileId, CacheEntry).init(alloc),
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.clearFiles();
        self.clearCache();
        self.files.deinit(self.alloc);
        self.file_index.deinit();
        self.file_names.deinit();
        self.cache.deinit();
    }

    pub fn open(self: *Workspace, name: []const u8, text: []const u8) !FileId {
        if (self.file_names.get(name)) |id| {
            try self.change(id, text);
            return id;
        }

        const name_copy = try self.alloc.dupe(u8, name);
        const text_copy = try self.alloc.dupe(u8, text);
        var stored = false;
        errdefer if (!stored) {
            self.alloc.free(name_copy);
            self.alloc.free(text_copy);
        };

        const id = self.next_file_id;
        self.next_file_id += 1;

        try self.files.append(self.alloc, .{
            .id = id,
            .version = 1,
            .name = name_copy,
            .text = text_copy,
        });
        stored = true;
        errdefer {
            const removed = self.files.pop().?;
            self.alloc.free(removed.name);
            self.alloc.free(removed.text);
        }
        const index = self.files.items.len - 1;

        try self.file_index.put(id, index);
        errdefer _ = self.file_index.remove(id);

        try self.file_names.put(name_copy, id);
        errdefer _ = self.file_names.remove(name_copy);

        return id;
    }

    pub fn change(self: *Workspace, id: FileId, text: []const u8) !void {
        const entry = try self.entryPtr(id);
        const text_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_copy);
        self.alloc.free(entry.text);
        entry.text = text_copy;
        entry.version += 1;
        self.invalidateCache(id);
    }

    pub fn close(self: *Workspace, id: FileId) void {
        const index = self.file_index.get(id) orelse return;
        const removed = self.files.swapRemove(index).?;
        self.invalidateCache(id);
        _ = self.file_names.remove(removed.name);
        _ = self.file_index.remove(id);
        self.alloc.free(removed.name);
        self.alloc.free(removed.text);
        if (index < self.files.items.len) {
            const moved = self.files.items[index];
            self.file_index.put(moved.id, index) catch {};
        }
    }

    pub fn snapshot(self: *Workspace, id: FileId) ?Snapshot {
        const index = self.file_index.get(id) orelse return null;
        const entry = self.files.items[index];
        return .{
            .id = entry.id,
            .version = entry.version,
            .name = entry.name,
            .text = entry.text,
        };
    }

    pub fn analyze(self: *Workspace, alloc: std.mem.Allocator, id: FileId, opts: lang.BuildOptions) !lang.BuildResult {
        const snap = self.snapshot(id) orelse return error.FileNotOpen;
        if (self.cache.get(id)) |cached| {
            if (cached.version == snap.version and sameOpts(cached.opts, opts)) {
                const artifact = try copyArtifact(alloc, cached.artifact);
                errdefer deinitArtifact(alloc, artifact);
                if (opts.install_debug_info) {
                    try self.vm.setProgramDebugInfo(artifact.spans, snap.text, snap.name);
                }
                return .{ .ok = artifact };
            }
        }

        const build_result = try lang.build(self.vm, .{
            .name = snap.name,
            .text = snap.text,
        }, opts);

        return switch (build_result) {
            .ok => |artifact| blk: {
                errdefer deinitArtifact(self.alloc, artifact);
                const copy = try copyArtifact(alloc, artifact);
                errdefer deinitArtifact(alloc, copy);
                try self.putCache(id, snap.version, opts, artifact);
                break :blk .{ .ok = copy };
            },
            .err => |err| .{ .err = err },
        };
    }

    pub fn analyzeSource(self: *Workspace, alloc: std.mem.Allocator, name: []const u8, text: []const u8, opts: lang.BuildOptions) !lang.BuildResult {
        const id = try self.open(name, text);
        return self.analyze(alloc, id, opts);
    }

    fn putCache(self: *Workspace, id: FileId, version: u32, opts: lang.BuildOptions, artifact: lang.Artifact) !void {
        const entry = CacheEntry{
            .version = version,
            .opts = opts,
            .artifact = artifact,
        };
        if (self.cache.getPtr(id)) |slot| {
            deinitArtifact(self.alloc, slot.artifact);
            slot.* = entry;
        } else {
            try self.cache.put(id, entry);
        }
    }

    fn invalidateCache(self: *Workspace, id: FileId) void {
        if (self.cache.fetchRemove(id)) |kv| {
            deinitArtifact(self.alloc, kv.value.artifact);
        }
    }

    fn clearFiles(self: *Workspace) void {
        while (self.files.items.len != 0) {
            const entry = self.files.pop().?;
            self.alloc.free(entry.name);
            self.alloc.free(entry.text);
        }
    }

    fn clearCache(self: *Workspace) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            deinitArtifact(self.alloc, entry.value_ptr.artifact);
        }
    }

    fn entryPtr(self: *Workspace, id: FileId) !*FileEntry {
        const index = self.file_index.get(id) orelse return error.FileNotOpen;
        return &self.files.items[index];
    }
};

fn sameOpts(a: lang.BuildOptions, b: lang.BuildOptions) bool {
    return a.include_default_macros == b.include_default_macros and
        a.install_debug_info == b.install_debug_info and
        a.test_mode == b.test_mode;
}

fn copyArtifact(alloc: std.mem.Allocator, artifact: lang.Artifact) !lang.Artifact {
    return .{
        .instructions = try alloc.dupe(revo.Instruction, artifact.instructions),
        .spans = try alloc.dupe(lang.Span, artifact.spans),
    };
}

fn deinitArtifact(alloc: std.mem.Allocator, artifact: lang.Artifact) void {
    alloc.free(artifact.instructions);
    alloc.free(artifact.spans);
}

test "workspace caches repeated analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io });
    defer vm.deinit();

    var ws = try Workspace.init(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1");
    const first = try ws.analyze(alloc, id, .{});
    defer switch (first) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };
    try std.testing.expect(first == .ok);

    const second = try ws.analyze(alloc, id, .{});
    defer switch (second) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };
    try std.testing.expect(second == .ok);
    try std.testing.expectEqual(first.ok.instructions.len, second.ok.instructions.len);
}

test "workspace invalidates cache on change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try VM.init(.{ .alloc = alloc, .io = std.testing.io });
    defer vm.deinit();

    var ws = try Workspace.init(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1");
    const first = try ws.analyze(alloc, id, .{});
    defer switch (first) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };

    try ws.change(id, "1 + 2");
    const snap = ws.snapshot(id).?;
    try std.testing.expectEqual(@as(u32, 2), snap.version);

    const second = try ws.analyze(alloc, id, .{});
    defer switch (second) {
        .ok => |artifact| {
            alloc.free(artifact.instructions);
            alloc.free(artifact.spans);
        },
        .err => |err| lang.deinitError(alloc, err),
    };
    try std.testing.expect(second == .ok);
}
