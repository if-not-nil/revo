const std = @import("std");
const revo = @import("revo");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const VM = revo.VM;

pub const Backend = build_options.@"build.build.ReplBackend";
pub const backend: Backend = build_options.repl_backend;

const libedit_c = if (backend == .libedit) @cImport({
    @cInclude("editline/readline.h");
}) else struct {};

const readline_c = if (backend == .readline) @cImport({
    @cInclude("readline/readline.h");
    @cInclude("readline/history.h");
}) else struct {};

const bestline_c = if (backend == .bestline) @cImport({
    @cInclude("bestline.h");
}) else struct {};

const signal_c = if (backend != .none) @cImport(@cInclude("signal.h")) else struct {};
const libc = @cImport(@cInclude("stdlib.h"));
const main = @import("main.zig");

fn readLine(init: std.process.Init) ![]u8 {
    return switch (backend) {
        .libedit => {
            const line = libedit_c.readline(">> ") orelse return error.EndOfStream;
            if (line[0] != 0) _ = libedit_c.add_history(line);
            const duped = try init.gpa.dupe(u8, std.mem.span(line));
            libc.free(line);
            return duped;
        },
        .readline => {
            const line = readline_c.readline(">> ") orelse return error.EndOfStream;
            if (line[0] != 0) _ = readline_c.add_history(line);
            const duped = try init.gpa.dupe(u8, std.mem.span(line));
            libc.free(line);
            return duped;
        },
        .bestline => {
            const line = bestline_c.bestlineWithHistory(">> ", "revo_history") orelse return error.EndOfStream;
            const duped = try init.gpa.dupe(u8, std.mem.span(line));
            libc.free(line);
            return duped;
        },
        .none => {
            var stdout_buffer: [8]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
            stdout.interface.writeAll(">> ") catch {};
            stdout.interface.flush() catch {};

            var stdin_buffer: [1024]u8 = undefined;
            var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
            var writer = std.Io.Writer.Allocating.init(init.gpa);
            defer writer.deinit();
            _ = try stdin_reader.interface.streamDelimiter(&writer.writer, '\n');
            return try writer.toOwnedSlice();
        },
    };
}

var sigint_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn sigintHandler(_: c_int) callconv(.c) void {
    sigint_received.store(true, .seq_cst);
}

const OS = @import("builtin").target.os.tag;

pub fn run(vm: *VM, gpa: Allocator, init: std.process.Init) !void {
    std.debug.print("revo " ++ build_options.version ++ " -- repl ({s} backend)\ntype :q to exit, :clear to reset session\n", .{@tagName(backend)});

    const signal_was_set = backend != .none and OS != .wasi;
    if (signal_was_set) _ = signal_c.signal(signal_c.SIGINT, @ptrCast(&sigintHandler));

    var source_acc = try std.ArrayList(u8).initCapacity(gpa, 256);
    defer source_acc.deinit(gpa);

    outer: while (true) {
        if (sigint_received.load(.seq_cst)) {
            sigint_received.store(false, .seq_cst);
            std.debug.print("\n", .{});
            source_acc.clearRetainingCapacity();
            continue;
        }

        // SAFETY: REPL exits on read error
        const raw = readLine(init) catch break;
        defer init.gpa.free(raw);
        const line = std.mem.trim(u8, raw, " \t\r\n");

        if (line.len == 0) continue :outer;
        if (std.mem.eql(u8, line, ":q") or std.mem.eql(u8, line, ":quit")) break :outer;

        if (std.mem.eql(u8, line, ":clear")) {
            source_acc.clearRetainingCapacity();
            vm.globals.clearRetainingCapacity();
            vm.const_globals.clearRetainingCapacity();
            std.debug.print("session cleared\n", .{});
            continue :outer;
        }

        if (std.mem.eql(u8, line, ":backend")) {
            std.debug.print("line editing: {s}\n", .{@tagName(backend)});
            continue :outer;
        }

        // SAFETY: REPL discards input on append/build errors
        source_acc.appendSlice(gpa, line) catch break :outer;
        source_acc.append(gpa, '\n') catch break :outer;

        const build_result = revo.lang.build(vm, .{ .name = "<repl>", .text = source_acc.items }, .{}) catch continue :outer;
        const artifact = switch (build_result) {
            .ok => |ok| ok,
            .err => continue :outer,
        };
        defer gpa.free(artifact.instructions);
        defer gpa.free(artifact.spans);

        vm.setProgramDebugInfo(artifact.spans, source_acc.items, "<repl>") catch {};

        const run_result = revo.module.runCompiledSessionReport(vm, "<repl>", artifact.instructions) catch |err| blk: {
            std.debug.print("runtime error: {}\n", .{err});
            break :blk null;
        } orelse break :outer;

        if (sigint_received.load(.seq_cst)) {
            sigint_received.store(false, .seq_cst);
            std.debug.print("\ninterrupt\n", .{});
            source_acc.clearRetainingCapacity();
            break :outer;
        }

        switch (run_result) {
            .ok => {
                const result = vm.mainResult();
                var w = std.Io.Writer.Allocating.init(gpa);
                defer w.deinit();
                try result.write(&w.writer, vm, .debug);
                std.debug.print("{s}\n", .{try w.toOwnedSlice()});
            },
            .err => |failure| main.printRuntimeFailure(init, failure, "<repl>"),
        }
        source_acc.clearRetainingCapacity();
    }

    if (signal_was_set) _ = signal_c.signal(signal_c.SIGINT, @ptrFromInt(0));
    std.debug.print("goodbye\n", .{});
}
