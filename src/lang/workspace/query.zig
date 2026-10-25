//! salsa-ish query inputs; content hashes, dirty when the hash moves

const std = @import("std");

const txt = @import("text.zig");

pub const FileId = txt.FileId;

/// always xxhash64 at seed 0
/// i only picked xxhash because vite and webpack use it for some reason
pub fn hashText(text: []const u8) u64 {
    return std.hash.XxHash64.hash(0, text);
}

pub const QueryInput = struct {
    hash: u64,
};

/// input table
/// dirty when current hash differs from recorded
pub const QueryDb = struct {
    alloc: std.mem.Allocator,
    inputs: std.AutoHashMap(FileId, QueryInput),

    pub fn init(alloc: std.mem.Allocator) QueryDb {
        return .{ .alloc = alloc, .inputs = std.AutoHashMap(FileId, QueryInput).init(alloc) };
    }

    pub fn deinit(self: *QueryDb) void {
        self.inputs.deinit();
    }

    /// record current text hash for a file
    pub fn track(self: *QueryDb, id: FileId, text: []const u8) !void {
        try self.inputs.put(id, .{ .hash = hashText(text) });
    }

    /// forget a closed file
    pub fn evict(self: *QueryDb, id: FileId) void {
        _ = self.inputs.remove(id);
    }

    /// true when the file is untracked or its text hash moved
    pub fn isDirty(self: *const QueryDb, id: FileId, text: []const u8) bool {
        const recorded = self.inputs.get(id) orelse return true;
        return recorded.hash != hashText(text);
    }
};

test "same text hashes stable, edits go dirty" {
    var db = QueryDb.init(std.testing.allocator);
    defer db.deinit();

    const id: FileId = 7;
    try std.testing.expect(db.isDirty(id, "let x = 1"));
    try db.track(id, "let x = 1");
    try std.testing.expect(!db.isDirty(id, "let x = 1"));
    try std.testing.expect(db.isDirty(id, "let x = 2"));

    db.evict(id);
    try std.testing.expect(db.isDirty(id, "let x = 1"));
}
