const std = @import("std");

const revo = @import("revo");

const memory = revo.memory;
const Data = memory.Data;

pub const StructTypeID = usize;

pub const StructField = struct {
    name_atom: memory.AtomID,
    type_atom: ?memory.AtomID = null,
    default_val: ?Data = null,
};

pub const StructDescriptor = struct {
    name: []const u8,
    fields: []const StructField,
    field_index: std.AutoHashMap(memory.AtomID, usize),
    methods: std.StringHashMap(Data),

    pub fn deinit(self: *StructDescriptor, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.fields);
        self.field_index.deinit();
        self.methods.deinit();
    }

    pub fn fieldIndex(self: *const StructDescriptor, name_atom: memory.AtomID) ?usize {
        return self.field_index.get(name_atom);
    }
};

pub const StructTypePool = struct {
    alloc: std.mem.Allocator,
    types: std.ArrayList(StructDescriptor),

    pub fn init(alloc: std.mem.Allocator) StructTypePool {
        return .{ .alloc = alloc, .types = std.ArrayList(StructDescriptor).initCapacity(alloc, 0) catch unreachable };
    }

    pub fn deinit(self: *StructTypePool) void {
        for (self.types.items) |*t| t.deinit(self.alloc);
        self.types.deinit(self.alloc);
    }

    pub fn registerType(self: *StructTypePool, name: []const u8, fields: []const StructField, methods: std.StringHashMap(Data)) !StructTypeID {
        var field_index = std.AutoHashMap(memory.AtomID, usize).init(self.alloc);
        errdefer field_index.deinit();
        for (fields, 0..) |f, idx| {
            try field_index.put(f.name_atom, idx);
        }
        const desc = StructDescriptor{
            .name = try self.alloc.dupe(u8, name),
            .fields = try self.alloc.dupe(StructField, fields),
            .field_index = field_index,
            .methods = methods,
        };
        const id: StructTypeID = self.types.items.len;
        try self.types.append(self.alloc, desc);
        return id;
    }

    pub fn getType(self: *StructTypePool, id: StructTypeID) ?*StructDescriptor {
        if (id >= self.types.items.len) return null;
        return &self.types.items[id];
    }

    pub fn isValid(self: *const StructTypePool, id: StructTypeID) bool {
        return id < self.types.items.len;
    }

    pub fn findTypeByName(self: *const StructTypePool, name: []const u8) ?StructTypeID {
        for (self.types.items, 0..) |*t, id| {
            if (std.mem.eql(u8, t.name, name)) return id;
        }
        return null;
    }

    pub fn findField(self: *StructTypePool, type_id: StructTypeID, name_atom: memory.AtomID) ?usize {
        const desc = self.getType(type_id) orelse return null;
        return desc.fieldIndex(name_atom);
    }

    pub fn getFieldName(self: *StructTypePool, type_id: StructTypeID, idx: usize) ?memory.AtomID {
        const desc = self.getType(type_id) orelse return null;
        if (idx >= desc.fields.len) return null;
        return desc.fields[idx].name_atom;
    }

    pub fn fieldCount(self: *StructTypePool, type_id: StructTypeID) ?usize {
        const desc = self.getType(type_id) orelse return null;
        return desc.fields.len;
    }
};

pub const StructInstanceID = usize;

pub const StructInstance = struct {
    type_id: StructTypeID,
    fields: []Data,

    pub fn deinit(self: *StructInstance, alloc: std.mem.Allocator) void {
        alloc.free(self.fields);
    }

    pub fn get(self: *StructInstance, field_idx: usize) Data {
        if (field_idx < self.fields.len) return self.fields[field_idx];
        return revo.core_atoms.data(.undef);
    }

    pub fn set(self: *StructInstance, field_idx: usize, val: Data) void {
        if (field_idx < self.fields.len) self.fields[field_idx] = val;
    }

    pub fn len(self: *const StructInstance) usize {
        return self.fields.len;
    }
};

pub const StructInstancePool = struct {
    alloc: std.mem.Allocator,
    instances: std.ArrayList(?StructInstance),
    marks: std.DynamicBitSet,
    dead: std.ArrayList(StructInstanceID),

    pub fn init(alloc: std.mem.Allocator) !StructInstancePool {
        return .{
            .alloc = alloc,
            .instances = try std.ArrayList(?StructInstance).initCapacity(alloc, 4),
            .marks = try std.DynamicBitSet.initEmpty(alloc, 64),
            .dead = try std.ArrayList(StructInstanceID).initCapacity(alloc, 0),
        };
    }

    pub fn deinit(self: *StructInstancePool) void {
        for (self.instances.items) |*maybe_s| {
            if (maybe_s.*) |*s| s.deinit(self.alloc);
        }
        self.instances.deinit(self.alloc);
        self.marks.deinit();
        self.dead.deinit(self.alloc);
    }

    pub fn create(self: *StructInstancePool, type_id: StructTypeID, field_count: usize) !StructInstanceID {
        const fields = try self.alloc.alloc(Data, field_count);
        @memset(fields, revo.core_atoms.data(.undef));
        errdefer self.alloc.free(fields);
        if (self.dead.pop()) |id| {
            self.instances.items[id] = StructInstance{ .type_id = type_id, .fields = fields };
            return id;
        }
        const id: StructInstanceID = @intCast(self.instances.items.len);
        try self.instances.append(self.alloc, StructInstance{ .type_id = type_id, .fields = fields });
        if (id >= self.marks.capacity()) {
            try self.marks.resize(self.instances.items.len, false);
        }
        return id;
    }

    pub fn get(self: *StructInstancePool, id: StructInstanceID) !*StructInstance {
        if (id >= self.instances.items.len) return error.InvalidStruct;
        if (self.instances.items[id]) |*s| return s;
        return error.InvalidStruct;
    }

    pub fn isValid(self: *const StructInstancePool, id: StructInstanceID) bool {
        return id < self.instances.items.len and self.instances.items[id] != null;
    }

    pub fn mark(self: *StructInstancePool, id: StructInstanceID, vm: *revo.VM) void {
        if (id >= self.instances.items.len) return;
        if (self.marks.isSet(id)) return;
        if (self.instances.items[id] == null) return;
        self.marks.set(id);
        vm.pushMarkStructInstance(id);
    }

    pub fn sweep(self: *StructInstancePool) void {
        const max_dead = self.instances.items.len;
        self.dead.ensureTotalCapacity(self.alloc, max_dead) catch return;
        self.dead.items.len = 0;
        for (self.instances.items, 0..) |*maybe_s, idx| {
            if (maybe_s.* == null) continue;
            if (self.marks.isSet(idx)) continue;
            maybe_s.*.?.deinit(self.alloc);
            maybe_s.* = null;
            self.dead.appendAssumeCapacity(@intCast(idx));
        }
        self.marks.unmanaged.unsetAll();
    }

    pub fn bytes(self: *const StructInstancePool) usize {
        var total: usize = 0;
        for (self.instances.items) |maybe_s| {
            if (maybe_s) |s| {
                total += @sizeOf(StructInstance);
                total += @sizeOf(Data) * s.fields.len;
            }
        }
        return total;
    }

    pub fn clearMarks(self: *StructInstancePool) void {
        self.marks.unmanaged.unsetAll();
    }

    pub fn capacity(self: *const StructInstancePool) usize {
        return self.instances.items.len;
    }

    pub fn sweepStep(self: *StructInstancePool, cursor: usize, limit: usize) usize {
        if (cursor >= self.instances.items.len) return 0;

        const end = @min(cursor + limit, self.instances.items.len);
        var processed: usize = 0;

        var i = cursor;
        while (i < end) : (i += 1) {
            if (self.instances.items[i]) |*s| {
                if (!self.marks.isSet(i)) {
                    s.deinit(self.alloc);
                    self.instances.items[i] = null;
                    self.dead.append(self.alloc, @intCast(i)) catch {};
                }
            }
            processed += 1;
        }

        return processed;
    }
};
