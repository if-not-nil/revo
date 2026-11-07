const revo = @import("../root.zig");
const root = @import("root.zig");
const std = @import("std");
const lib = revo.argparse;

const Value = revo.Value;
const VM = revo.VM;
const mem = revo.vm.memory;
const HostResult = root.host.HostResult;
const Args = root.host.ArgTypes;

pub const Impl = struct {
    pub fn parse(vm: *VM, builder_fn: Args.function, argv_tbl: Args.table) !HostResult {
        const alloc = vm.runtime.alloc;

        const arg_defs = try alloc.create(std.ArrayList(lib.Arg));
        arg_defs.* = .empty;

        const cmd_defs = try alloc.create(std.ArrayList(lib.Command));
        cmd_defs.* = .empty;

        const builder_id = try vm.tables.create();
        try vm.putField(builder_id, "_args_ptr", Value.new.@"opaque"(arg_defs));
        try vm.putField(builder_id, "_cmds_ptr", Value.new.@"opaque"(cmd_defs));

        const install = struct {
            fn go(vm_: *VM, tbl_id: mem.TableID, comptime name: []const u8, func: root.host.HostFn) !void {
                const fn_id = try vm_.installHost(name, .{
                    .arity = 1,
                    .variadic = true,
                    .param_types = &.{.any},
                    .func = func,
                });
                try vm_.putField(tbl_id, name, Value.new.function(fn_id));
            }
        };
        try install.go(vm, builder_id, "flag", builderFlagFn);
        try install.go(vm, builder_id, "option", builderOptionFn);
        try install.go(vm, builder_id, "command", builderCommandFn);
        try install.go(vm, builder_id, "positional", builderPositionalFn);

        _ = try vm.callFunctionParts(Value.new.function(@backingInt(builder_fn)), null, &[_]Value{Value.new.table(builder_id)}, null);

        const argv = try vm.tables.get(@backingInt(argv_tbl));
        var argv_buf: [128][:0]const u8 = undefined;
        const raw_len = argv.array.items.len;
        const start: usize = if (raw_len > 1) 1 else 0;
        const len = @min(raw_len - start, 128);
        for (0..len) |i| {
            const item = argv.array.items[start + i];
            argv_buf[i] = if (item.asString()) |sid|
                try alloc.dupeSentinel(u8, vm.stringValue(sid), 0)
            else
                "";
        }

        var leftover: std.ArrayList([:0]const u8) = .empty;
        defer leftover.deinit(alloc);

        var res = lib.Result{
            .args = arg_defs.items,
            .commands = cmd_defs.items,
            .leftover = &leftover,
        };

        lib.parse(alloc, argv_buf[0..len], &res) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnexpectedLongArg, error.UnexpectedShortArg, error.MissingValue => {
                const err_table_id = try vm.tables.create();
                if (res.err_token) |token| {
                    try vm.putField(err_table_id, "token", try vm.ownValueString(token));
                }
                const msg = switch (err) {
                    error.UnexpectedLongArg => "unexpected long arg",
                    error.UnexpectedShortArg => "unexpected short arg",
                    error.MissingValue => "missing value",
                    else => unreachable,
                };
                try vm.putField(err_table_id, "message", try vm.ownValueString(msg));

                const result_id = try vm.tables.create();
                try vm.putField(result_id, "err", Value.new.table(err_table_id));
                try vm.putField(result_id, "flags", Value.new.core(.nil));
                try vm.putField(result_id, "commands", Value.new.core(.nil));
                try vm.putField(result_id, "positionals", Value.new.core(.nil));
                try vm.putField(result_id, "leftover", Value.new.core(.nil));
                try vm.putField(result_id, "_args", Value.new.@"opaque"(arg_defs));
                try vm.putField(result_id, "_cmds", Value.new.@"opaque"(cmd_defs));
                return .data(Value.new.table(result_id));
            },
        };

        const result_id = try vm.tables.create();

        const flags_id = try vm.tables.create();
        for (arg_defs.items) |*arg| {
            if (arg.kind == .positional) continue;
            if (arg.kind == .boolean) {
                try vm.putField(flags_id, arg.name, Value.new.boolean(arg.enabled));
            } else if (arg.value) |v| {
                try vm.putField(flags_id, arg.name, try vm.ownValueString(v));
            }
        }
        try vm.putField(result_id, "flags", Value.new.table(flags_id));

        const cmds_id = try vm.tables.create();
        for (cmd_defs.items) |*cmd| {
            try vm.putField(cmds_id, cmd.name, Value.new.boolean(cmd.triggered));
        }
        try vm.putField(result_id, "commands", Value.new.table(cmds_id));

        const pos_id = try vm.tables.create();
        for (arg_defs.items) |*arg| {
            if (arg.kind != .positional) continue;
            if (arg.value) |v| {
                try vm.putField(pos_id, arg.name, try vm.ownValueString(v));
            }
        }
        try vm.putField(result_id, "positionals", Value.new.table(pos_id));

        const lo_id = try vm.tables.create();
        const lo = try vm.tables.get(lo_id);
        for (leftover.items) |item| {
            try lo.push(vm.runtime.alloc, try vm.ownValueString(item));
        }
        try vm.putField(result_id, "leftover", Value.new.table(lo_id));

        try vm.putField(result_id, "err", Value.new.core(.nil));
        try vm.putField(result_id, "_args", Value.new.@"opaque"(arg_defs));
        try vm.putField(result_id, "_cmds", Value.new.@"opaque"(cmd_defs));

        return .data(Value.new.table(result_id));
    }
    pub fn usage(vm: *VM, result_tbl: Args.table) !HostResult {
        const result = Value.new.table(@backingInt(result_tbl));

        const arg_defs_ptr = vm.getField(result, "_args") orelse return error.InvalidState;
        const cmd_defs_ptr = vm.getField(result, "_cmds") orelse return error.InvalidState;

        const arg_defs: *std.ArrayList(lib.Arg) = @ptrCast(@alignCast(arg_defs_ptr.asOpaque().?));
        const cmd_defs: *std.ArrayList(lib.Command) = @ptrCast(@alignCast(cmd_defs_ptr.asOpaque().?));

        const text = try lib.usage(vm.runtime.alloc, arg_defs.items, cmd_defs.items);
        defer vm.runtime.alloc.free(text);

        return .data(try vm.ownValueString(text));
    }
};

pub const impls = root.host.impls(Impl).val;

// -- [builder methods] -------------------------------------------------------

fn isTrue(d: Value) bool {
    if (d.asAtom()) |a| return a == revo.CoreAtoms.atomId(.true);
    return false;
}

fn fieldStr(val: Value, vm: *VM, name: []const u8) ?[]const u8 {
    const field = vm.getField(val, name) orelse return null;
    const sid = field.asString() orelse return null;
    return vm.stringValue(sid);
}

fn fieldBool(val: Value, vm: *VM, name: []const u8) bool {
    const field = vm.getField(val, name) orelse return false;
    return isTrue(field);
}

fn builderFlagFn(args: []const Value, vm: *VM) !HostResult {
    return builderAddArgFn(args, vm, .boolean);
}

fn builderOptionFn(args: []const Value, vm: *VM) !HostResult {
    return builderAddArgFn(args, vm, .string);
}

fn builderPositionalFn(args: []const Value, vm: *VM) !HostResult {
    return builderAddArgFn(args, vm, .positional);
}

const ArgKind = enum { boolean, string, positional };

fn builderAddArgFn(args: []const Value, vm: *VM, kind: ArgKind) !HostResult {
    const name_atom = args[1].asAtom() orelse return .errType(1, "atom", root.typeof(args[1], vm));

    var short: ?u8 = null;
    var description: []const u8 = "";
    var terminal = false;
    var passthrough = false;

    if (args.len > 2 and args[2].isTable()) {
        if (fieldStr(args[2], vm, "short")) |s| {
            if (s.len > 0) short = s[0];
        }
        description = fieldStr(args[2], vm, "description") orelse "";
        terminal = fieldBool(args[2], vm, "terminal");
        passthrough = fieldBool(args[2], vm, "passthrough");
    }

    if (args[0].asTable() == null) return .errType(0, "table", root.typeof(args[0], vm));
    const args_list_ptr = vm.getField(args[0], "_args_ptr") orelse return error.InvalidState;

    const list: *std.ArrayList(lib.Arg) = @ptrCast(@alignCast(args_list_ptr.asOpaque().?));
    try list.append(vm.runtime.alloc, .{
        .name = vm.stringValue(name_atom),
        .short = short,
        .kind = switch (kind) {
            .boolean => .boolean,
            .string => .string,
            .positional => .positional,
        },
        .description = description,
        .terminal = terminal,
        .passthrough = passthrough,
    });

    return .data(args[0]);
}

fn builderCommandFn(args: []const Value, vm: *VM) !HostResult {
    const name_atom = args[1].asAtom() orelse return .errType(1, "atom", root.typeof(args[1], vm));

    var description: []const u8 = "";
    var prefix = false;

    if (args.len > 2 and args[2].isTable()) {
        description = fieldStr(args[2], vm, "description") orelse "";
        prefix = fieldBool(args[2], vm, "prefix");
    }

    if (args[0].asTable() == null) return .errType(0, "table", root.typeof(args[0], vm));
    const cmds_list_ptr = vm.getField(args[0], "_cmds_ptr") orelse return error.InvalidState;

    const list: *std.ArrayList(lib.Command) = @ptrCast(@alignCast(cmds_list_ptr.asOpaque().?));
    try list.append(vm.runtime.alloc, .{
        .name = vm.stringValue(name_atom),
        .description = description,
        .prefix = prefix,
    });

    return .data(args[0]);
}
