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

const isocline_c = if (backend == .isocline) @cImport({
    @cInclude("isocline.h");
}) else struct {};

const signal_c = if (backend != .none) @cImport(@cInclude("signal.h")) else struct {};
const libc = @cImport(@cInclude("stdlib.h"));

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
        .isocline => {
            const line = isocline_c.ic_readline("rεvo") orelse return error.EndOfStream;
            // isocline_c.ic_set_history(isocline_c.NULL, -1);

            if (line[0] != 0)
                _ = isocline_c.ic_history_add(line);

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

pub const Session = struct {
    vm: *VM,
    gpa: Allocator,
    source_acc: std.ArrayList(u8),

    pub fn init(vm: *VM, gpa: Allocator) !Session {
        return .{
            .vm = vm,
            .gpa = gpa,
            .source_acc = try std.ArrayList(u8).initCapacity(gpa, 256),
        };
    }

    pub fn deinit(self: *Session) void {
        self.source_acc.deinit(self.gpa);
    }

    fn clear(self: *Session) void {
        self.source_acc.clearRetainingCapacity();
        self.vm.globals.clearRetainingCapacity();
        self.vm.const_globals.clearRetainingCapacity();
    }

    fn printResult(self: *Session, out: *std.Io.Writer) !void {
        var w = std.Io.Writer.Allocating.init(self.gpa);
        defer w.deinit();
        try self.vm.mainResult().write(&w.writer, self.vm, .debug);
        try out.writeAll(w.written());
        try out.writeAll("\n");
    }

    fn printBuildError(self: *Session, out: *std.Io.Writer, err: revo.lang.Error) !void {
        var buf = std.Io.Writer.Allocating.init(self.gpa);
        defer buf.deinit();
        try revo.lang.renderError(self.gpa, &buf.writer, .{ .name = "<repl>", .text = self.source_acc.items }, err);
        try out.writeAll(buf.written());
        revo.lang.deinitError(self.gpa, err);
    }

    fn printRuntimeFailure(self: *Session, out: *std.Io.Writer, failure: revo.EvalFailure) !void {
        var buf = std.Io.Writer.Allocating.init(self.gpa);
        defer buf.deinit();
        try failure.render(self.gpa, &buf.writer, self.source_acc.items);
        try out.writeAll(buf.written());
    }

    pub fn step(self: *Session, out: *std.Io.Writer, raw_line: []const u8) !bool {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");

        if (line.len == 0) return true;
        if (std.mem.eql(u8, line, ":q") or std.mem.eql(u8, line, ":quit")) return false;

        if (std.mem.eql(u8, line, ":clear")) {
            self.clear();
            try out.writeAll("session cleared\n");
            return true;
        }

        if (std.mem.eql(u8, line, ":backend")) {
            try out.print("line editing: {s}\n", .{@tagName(backend)});
            return true;
        }

        const snip_len = line.len + 1;
        var snip_mem = try self.gpa.alloc(u8, snip_len);
        @memcpy(snip_mem[0..line.len], line);
        snip_mem[line.len] = '\n';
        const snippet = snip_mem[0..snip_len];

        const snip_build = revo.lang.build(self.vm, .{ .name = "<repl>", .text = snippet }, .{}) catch |err| {
            self.gpa.free(snip_mem);
            try out.print("repl build error: {}\n", .{err});
            return true;
        };

        switch (snip_build) {
            .ok => |artifact| {
                defer self.gpa.free(snip_mem);
                defer self.gpa.free(artifact.instructions);
                defer self.gpa.free(artifact.spans);

                self.vm.setProgramDebugInfo(artifact.spans, snippet, "<repl>") catch {};

                const run_result = revo.module.runCompiledSessionReport(self.vm, "<repl>", artifact.instructions) catch |err| {
                    try out.print("runtime error: {}\n", .{err});
                    self.clear();
                    return true;
                };

                switch (run_result) {
                    .ok => try self.printResult(out),
                    .err => |failure| {
                        try self.printRuntimeFailure(out, failure);
                        self.clear();
                        return true;
                    },
                }

                return true;
            },
            .err => {
                self.gpa.free(snip_mem);
                try self.source_acc.appendSlice(self.gpa, line);
                try self.source_acc.append(self.gpa, '\n');

                const build_result = revo.lang.build(self.vm, .{ .name = "<repl>", .text = self.source_acc.items }, .{}) catch |build_err| {
                    try out.print("repl build error: {}\n", .{build_err});
                    return true;
                };
                const artifact = switch (build_result) {
                    .ok => |ok| ok,
                    .err => |err2| {
                        try self.printBuildError(out, err2);
                        return true;
                    },
                };
                defer self.gpa.free(artifact.instructions);
                defer self.gpa.free(artifact.spans);

                self.vm.setProgramDebugInfo(artifact.spans, self.source_acc.items, "<repl>") catch {};

                const run_result = revo.module.runCompiledSessionReport(self.vm, "<repl>", artifact.instructions) catch |run_err| {
                    try out.print("runtime error: {}\n", .{run_err});
                    self.clear();
                    return true;
                };

                switch (run_result) {
                    .ok => {
                        self.source_acc.clearRetainingCapacity();
                        try self.printResult(out);
                    },
                    .err => |failure| {
                        try self.printRuntimeFailure(out, failure);
                        self.clear();
                        return true;
                    },
                }

                return true;
            },
        }
    }
};

pub fn run(vm: *VM, gpa: Allocator, init: std.process.Init) !void {
    var banner_buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &banner_buffer);
    const writer = &out.interface;
    const banner = try std.fmt.allocPrint(gpa, "revo {s} -- repl ({s} backend)\ntype :q to exit, :clear to reset session\n", .{ build_options.version, @tagName(backend) });
    defer gpa.free(banner);
    try writer.writeAll(banner);
    try writer.flush();

    const signal_was_set = backend != .none and OS != .wasi;
    if (signal_was_set) _ = signal_c.signal(signal_c.SIGINT, @ptrCast(&sigintHandler));

    var session = try Session.init(vm, gpa);
    defer session.deinit();

    while (true) {
        if (sigint_received.load(.seq_cst)) {
            sigint_received.store(false, .seq_cst);
            try writer.writeAll("\n");
            try writer.flush();
            session.clear();
            continue;
        }

        const raw = readLine(init) catch break;
        defer init.gpa.free(raw);
        if (!try session.step(writer, raw)) break;
        try writer.flush();

        if (sigint_received.load(.seq_cst)) {
            sigint_received.store(false, .seq_cst);
            try writer.writeAll("\ninterrupt\n");
            try writer.flush();
            session.clear();
            break;
        }
    }

    if (signal_was_set) _ = signal_c.signal(signal_c.SIGINT, @ptrFromInt(0));
    try writer.writeAll("goodbye\n");
    try writer.flush();
}

const TestEnv = struct {
    vm: revo.VM,
    session: Session,
    out: std.Io.Writer.Allocating,
};

fn initTestEnv() !TestEnv {
    const vm = try revo.VM.init(.{ .alloc = std.testing.allocator, .io = std.testing.io });
    const session = try Session.init(&vm, std.testing.allocator);
    const out = std.Io.Writer.Allocating.init(std.testing.allocator);
    return TestEnv{ .vm = vm, .session = session, .out = out };
}

// keep tests short by using initTestEnv
test "repl prints results" {
    var env = try initTestEnv();
    defer env.session.deinit();
    defer env.out.deinit();
    defer env.vm.deinit();

    try std.testing.expect(try env.session.step(&env.out.writer, "1 + 1"));
    try std.testing.expectEqualStrings("2\n", env.out.written());
}

test "repl renders parse errors" {
    var env = try initTestEnv();
    defer env.session.deinit();
    defer env.out.deinit();
    defer env.vm.deinit();

    try std.testing.expect(try env.session.step(&env.out.writer, "1 +"));
    try std.testing.expect(std.mem.indexOf(u8, env.out.written(), "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.out.written(), "1 +") != null);
    try std.testing.expect(std.mem.endsWith(u8, env.session.source_acc.items, "1 +\n"));
}

test "repl handles commands" {
    var env = try initTestEnv();
    defer env.session.deinit();
    defer env.out.deinit();
    defer env.vm.deinit();

    try env.vm.globals.put(1, revo.Data.new.nil());
    try env.vm.const_globals.put(2, {});
    try env.session.source_acc.appendSlice(std.testing.allocator, "pending");

    try std.testing.expect(try env.session.step(&env.out.writer, ":clear"));
    try std.testing.expectEqual(@as(usize, 0), env.vm.globals.count());
    try std.testing.expectEqual(@as(usize, 0), env.vm.const_globals.count());
    try std.testing.expectEqual(@as(usize, 0), env.session.source_acc.items.len);
    try std.testing.expect(std.mem.indexOf(u8, env.out.written(), "session cleared") != null);
    try std.testing.expect(!(try env.session.step(&env.out.writer, ":q")));
}
