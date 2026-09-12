const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");
const argparse = revo.argparse;

const Data = revo.Data;
const VM = revo.VM;
const mem = revo.vm.memory;
const HostResult = root.HostResult;
const Ts = root.T;

pub const Impl = struct {
    pub fn parse(vm: *VM, builder_fn: Ts.function, argv_tbl: Ts.table) !HostResult {
        const alloc = vm.runtime.alloc;

        const arg_defs = try alloc.create(std.ArrayList(argparse.Arg));
        arg_defs.* = .empty;

        const cmd_defs = try alloc.create(std.ArrayList(argparse.Command));
        cmd_defs.* = .empty;

        const builder_id = try vm.tables.create();
        try vm.putField(builder_id, "_args_ptr", Data.new.foreign(arg_defs));
        try vm.putField(builder_id, "_cmds_ptr", Data.new.foreign(cmd_defs));

        const install = struct {
            fn go(vm_: *VM, tbl_id: mem.TableID, comptime name: []const u8, func: root.HostFn) !void {
                const fn_id = try vm_.installHost(name, .{
                    .arity = 1,
                    .variadic = true,
                    .param_types = &.{.any},
                    .func = func,
                });
                try vm_.putField(tbl_id, name, Data.new.function(fn_id));
            }
        };
        try install.go(vm, builder_id, "flag", builderFlagFn);
        try install.go(vm, builder_id, "option", builderOptionFn);
        try install.go(vm, builder_id, "command", builderCommandFn);
        try install.go(vm, builder_id, "positional", builderPositionalFn);

        _ = try vm.callFunctionParts(Data.new.function(@intFromEnum(builder_fn)), null, &[_]Data{Data.new.table(builder_id)}, null);

        const argv = try vm.tables.get(@intFromEnum(argv_tbl));
        var argv_buf: [128][:0]const u8 = undefined;
        const raw_len = argv.array.items.len;
        const start: usize = if (raw_len > 1) 1 else 0;
        const len = @min(raw_len - start, 128);
        for (0..len) |i| {
            const item = argv.array.items[start + i];
            argv_buf[i] = if (item.asString()) |sid|
                try alloc.dupeZ(u8, vm.stringValue(sid))
            else
                "";
        }

        var leftover: std.ArrayList([:0]const u8) = .empty;
        defer leftover.deinit(alloc);

        var res = argparse.Result{
            .args = arg_defs.items,
            .commands = cmd_defs.items,
            .leftover = &leftover,
        };

        argparse.parse(alloc, argv_buf[0..len], &res) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnexpectedLongArg, error.UnexpectedShortArg, error.MissingValue => {
                const err_table_id = try vm.tables.create();
                if (res.err_token) |token| {
                    try vm.putField(err_table_id, "token", try vm.ownDataString(token));
                }
                const msg = switch (err) {
                    error.UnexpectedLongArg => "unexpected long arg",
                    error.UnexpectedShortArg => "unexpected short arg",
                    error.MissingValue => "missing value",
                    else => unreachable,
                };
                try vm.putField(err_table_id, "message", try vm.ownDataString(msg));

                const result_id = try vm.tables.create();
                try vm.putField(result_id, "err", Data.new.table(err_table_id));
                try vm.putField(result_id, "flags", Data.new.core(.nil));
                try vm.putField(result_id, "commands", Data.new.core(.nil));
                try vm.putField(result_id, "positionals", Data.new.core(.nil));
                try vm.putField(result_id, "leftover", Data.new.core(.nil));
                try vm.putField(result_id, "_args", Data.new.foreign(arg_defs));
                try vm.putField(result_id, "_cmds", Data.new.foreign(cmd_defs));
                return .data(Data.new.table(result_id));
            },
        };

        const result_id = try vm.tables.create();

        const flags_id = try vm.tables.create();
        for (arg_defs.items) |*arg| {
            if (arg.kind == .positional) continue;
            if (arg.kind == .boolean) {
                try vm.putField(flags_id, arg.name, Data.new.boolean(arg.enabled));
            } else if (arg.value) |v| {
                try vm.putField(flags_id, arg.name, try vm.ownDataString(v));
            }
        }
        try vm.putField(result_id, "flags", Data.new.table(flags_id));

        const cmds_id = try vm.tables.create();
        for (cmd_defs.items) |*cmd| {
            try vm.putField(cmds_id, cmd.name, Data.new.boolean(cmd.triggered));
        }
        try vm.putField(result_id, "commands", Data.new.table(cmds_id));

        const pos_id = try vm.tables.create();
        for (arg_defs.items) |*arg| {
            if (arg.kind != .positional) continue;
            if (arg.value) |v| {
                try vm.putField(pos_id, arg.name, try vm.ownDataString(v));
            }
        }
        try vm.putField(result_id, "positionals", Data.new.table(pos_id));

        const lo_id = try vm.tables.create();
        const lo = try vm.tables.get(lo_id);
        for (leftover.items) |item| {
            try lo.push(vm.runtime.alloc, try vm.ownDataString(item));
        }
        try vm.putField(result_id, "leftover", Data.new.table(lo_id));

        try vm.putField(result_id, "err", Data.new.core(.nil));
        try vm.putField(result_id, "_args", Data.new.foreign(arg_defs));
        try vm.putField(result_id, "_cmds", Data.new.foreign(cmd_defs));

        return .data(Data.new.table(result_id));
    }
    pub fn usage(vm: *VM, result_tbl: Ts.table) !HostResult {
        const result = Data.new.table(@intFromEnum(result_tbl));

        const arg_defs_ptr = vm.getField(result, "_args") orelse return error.InvalidState;
        const cmd_defs_ptr = vm.getField(result, "_cmds") orelse return error.InvalidState;

        const arg_defs: *std.ArrayList(argparse.Arg) = @ptrCast(@alignCast(arg_defs_ptr.asForeign().?));
        const cmd_defs: *std.ArrayList(argparse.Command) = @ptrCast(@alignCast(cmd_defs_ptr.asForeign().?));

        const text = try argparse.usage(vm.runtime.alloc, arg_defs.items, cmd_defs.items);
        defer vm.runtime.alloc.free(text);

        return .data(try vm.ownDataString(text));
    }
};

pub const impls = root.impls(Impl).val;

// -- [builder methods] -------------------------------------------------------

fn isTrue(d: Data) bool {
    if (d.asAtom()) |a| return a == revo.core_atoms.atomId(.true);
    return false;
}

fn fieldStr(val: Data, vm: *VM, name: []const u8) ?[]const u8 {
    const field = vm.getField(val, name) orelse return null;
    const sid = field.asString() orelse return null;
    return vm.stringValue(sid);
}

fn fieldBool(val: Data, vm: *VM, name: []const u8) bool {
    const field = vm.getField(val, name) orelse return false;
    return isTrue(field);
}

fn builderFlagFn(args: []const Data, vm: *VM) !HostResult {
    return builderAddArgFn(args, vm, .boolean);
}

fn builderOptionFn(args: []const Data, vm: *VM) !HostResult {
    return builderAddArgFn(args, vm, .string);
}

fn builderPositionalFn(args: []const Data, vm: *VM) !HostResult {
    return builderAddArgFn(args, vm, .positional);
}

const ArgKind = enum { boolean, string, positional };

fn builderAddArgFn(args: []const Data, vm: *VM, kind: ArgKind) !HostResult {
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

    const list: *std.ArrayList(argparse.Arg) = @ptrCast(@alignCast(args_list_ptr.asForeign().?));
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

fn builderCommandFn(args: []const Data, vm: *VM) !HostResult {
    const name_atom = args[1].asAtom() orelse return .errType(1, "atom", root.typeof(args[1], vm));

    var description: []const u8 = "";
    var prefix = false;

    if (args.len > 2 and args[2].isTable()) {
        description = fieldStr(args[2], vm, "description") orelse "";
        prefix = fieldBool(args[2], vm, "prefix");
    }

    if (args[0].asTable() == null) return .errType(0, "table", root.typeof(args[0], vm));
    const cmds_list_ptr = vm.getField(args[0], "_cmds_ptr") orelse return error.InvalidState;

    const list: *std.ArrayList(argparse.Command) = @ptrCast(@alignCast(cmds_list_ptr.asForeign().?));
    try list.append(vm.runtime.alloc, .{
        .name = vm.stringValue(name_atom),
        .description = description,
        .prefix = prefix,
    });

    return .data(args[0]);
}
