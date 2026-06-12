const std = @import("std");
const revo = @import("revo");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const VM = revo.VM;
const builtin = @import("builtin");

const isocline_c = if (build_options.isocline) @cImport({
    @cInclude("isocline.h");
}) else struct {};

const signal_c = if (build_options.isocline) @cImport(@cInclude("signal.h")) else struct {};
const libc = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
});

const IsoclineContext = struct {
    vm: *VM,
    gpa: Allocator,
};

var isocline_ctx: ?IsoclineContext = null;

const splash_texts = [_][]const u8{
    "hi",
    "make your readme .nfo",
    "the moon is flat",
    "the earth landing is fake",
    "It took Python 33 years to get syntax highlighting in REPL btw",
    "used to be the first language on earth",
    "try :h [function_name] or :h [any_variable]",
    "on course to have a negative amount of dependencies by 2030",
    switch (builtin.os.tag) {
        .hurd => "monolithic kernels suck",
        .linux => "linux is better than macos",
        .windows => "windows is better than linux",
        .macos => "macos is the best unix",
        .freebsd => "freebsd is better than linux",
        .netbsd => "freebsd is too bloated",
        .openbsd => "freebsd is too vulnerable",
        .plan9 => "computers are made for mice",
        .serenity => "ladybird is better than gecko",
        .haiku => "ladybird is better than gecko",
        else => "woah",
    },
    blk: {
        const cpu = builtin.cpu.model.name;
        if (std.mem.count(u8, cpu, "amd") > 0) {
            break :blk "intel is better";
        } else if (std.mem.count(u8, cpu, "intel") > 0) {
            break :blk "amd is better";
        } else if (std.mem.count(u8, cpu, "cortex") > 0) {
            break :blk "risc-v is better";
        } else if (std.mem.startsWith(u8, cpu, "rv")) {
            break :blk "arm is better";
        } else if (std.mem.count(u8, cpu, "apple") > 0) {
            break :blk "how's it feel to share ram with vram";
        } else break :blk "woah";
    },
};

fn splashText(seed: usize) []const u8 {
    const idx = seed % splash_texts.len;
    return splash_texts[idx];
}

fn splashSeed(vm: *VM, banner_buffer: *[128]u8, out: *std.Io.Writer) usize {
    var seed: u64 = @intFromPtr(vm);
    seed ^= @intFromPtr(banner_buffer);
    seed ^= @intFromPtr(out);
    seed ^= @intFromPtr(&splash_texts);
    if (@import("builtin").target.requiresLibC())
        seed ^= @as(u64, @intCast(libc.getpid())) << 32;
    seed ^= @as(u64, @intFromPtr(&splashSeed)) >> 1;
    var rng = std.Random.SplitMix64.init(seed);
    return @intCast(rng.next());
}

fn isoclineCompleter(cenv: ?*isocline_c.ic_completion_env_t, prefix: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (cenv == null) return;
    _ = isocline_c.ic_complete_word(cenv, prefix, @ptrCast(&isoclineWordCompleter), null);
}

fn isoclineWordCompleter(cenv: ?*isocline_c.ic_completion_env_t, word: [*c]const u8) callconv(.c) void {
    if (isocline_ctx == null or cenv == null) return;
    const wlen = libc.strlen(word);
    const wslice = word[0..wlen];

    var buf: [256]u8 = undefined;

    const commands = &[_][]const u8{ ":q", ":quit", ":clear", ":features", ":h", ":help", ":doc", ":apropos", ":doctest" };
    for (commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, wslice)) {
            const cmd_c = std.fmt.bufPrintZ(&buf, "{s}", .{cmd}) catch continue;
            _ = isocline_c.ic_add_completion(cenv, cmd_c);
        }
    }

    // add stdlib globals first, only then module globals so they get priority
    const ctx = isocline_ctx.?;
    const vm = ctx.vm;

    var s_it = vm.stdlib_globals.iterator();
    while (s_it.next()) |entry| {
        const name = vm.atomName(entry.key_ptr.*);
        if (std.mem.startsWith(u8, name, wslice)) {
            const n_c = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch continue;
            _ = isocline_c.ic_add_completion(cenv, n_c);
        }
    }

    var g_it = vm.globals.iterator();
    while (g_it.next()) |entry| {
        const name = vm.atomName(entry.key_ptr.*);
        if (std.mem.startsWith(u8, name, wslice)) {
            const n_c = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch continue;
            _ = isocline_c.ic_add_completion(cenv, n_c);
        }
    }

    // ...then keywords
    for (revo.lang.Lexer.TokenType.of_string.keys()) |kw| {
        if (std.mem.startsWith(u8, kw, wslice)) {
            const kw_c = std.fmt.bufPrintZ(&buf, "{s}", .{kw}) catch continue;
            _ = isocline_c.ic_add_completion(cenv, kw_c);
        }
    }
}

fn isoclineHighlighter(henv: ?*isocline_c.ic_highlight_env_t, input: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (henv == null) return;
    const input_len = libc.strlen(input);
    if (input_len == 0) return;
    const input_slice = input[0..input_len];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = switch (revo.lang.lexReport(alloc, input_slice) catch return) {
        .ok => |t| t,
        .err => {
            isocline_c.ic_highlight_formatted(henv, input, input);
            return;
        },
    };

    var fb = std.ArrayList(u8).initCapacity(alloc, input_len + 32) catch return;

    var last: usize = 0;
    for (tokens) |tok| {
        const tstart = tok.start;
        const tend = tok.end;
        if (tend <= tstart) continue;

        if (tstart > last) fb.appendSlice(alloc, input_slice[last..tstart]) catch {};

        var style: ?[]const u8 = switch (tok.type) {
            .number => "number",
            .string, .multiline_string, .backtick_string => "string",
            .kw_const, .kw_let, .kw_macro, .kw_test, .kw_suite, .kw_skip, .kw_struct, .kw_type, .kw_fn, .kw_if, .kw_else, .kw_match, .kw_when, .kw_do, .kw_end, .kw_loop, .kw_for, .kw_while, .kw_global, .kw_in, .kw_break, .kw_return, .kw_import, .kw_spawn, .kw_join, .kw_yield, .kw_and, .kw_or, .kw_not, .kw_comp, .kw_proc, .kw_orelse => "keyword",
            .plus, .minus, .star, .slash, .percent, .eq, .neq, .lt, .gt, .lte, .gte, .assign, .plus_assign, .minus_assign, .star_assign, .slash_assign, .percent_assign, .arrow, .dot, .dotdot, .colon, .comma, .pipe, .pipe_forward, .huh, .lparen, .rparen, .lbracket, .rbracket, .lsquiggly, .rsquiggly => "operator",
            .hash => "hash",
            else => null,
        };

        if (style == null and tok.type == .ident) {
            var pos = tend;
            while (pos < input_slice.len and std.ascii.isWhitespace(input_slice[pos])) pos += 1;
            if (pos < input_slice.len and input_slice[pos] == '(') style = "function";
        }

        if (style) |s| {
            fb.appendSlice(alloc, "[") catch {};
            fb.appendSlice(alloc, s) catch {};
            fb.appendSlice(alloc, "]") catch {};
            fb.appendSlice(alloc, input_slice[tstart..tend]) catch {};
            fb.appendSlice(alloc, "[/]") catch {};
        } else {
            fb.appendSlice(alloc, input_slice[tstart..tend]) catch {};
        }

        last = tend;
    }

    if (last < input_slice.len) fb.appendSlice(alloc, input_slice[last..]) catch {};
    fb.append(alloc, 0) catch {};
    isocline_c.ic_highlight_formatted(henv, input, fb.items.ptr);
}

fn readLine(init: std.process.Init) ![]u8 {
    if (build_options.isocline) {
        const line = isocline_c.ic_readline("rεvo ") orelse return error.EndOfStream;
        if (line[0] != 0)
            _ = isocline_c.ic_history_add(line);
        const duped = try init.gpa.dupe(u8, std.mem.span(line));
        isocline_c.ic_free(line);
        return duped;
    } else {
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
    }
}

var sigint_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn sigintHandler(_: c_int) callconv(.c) void {
    sigint_received.store(true, .seq_cst);
}

const OS = @import("builtin").target.os.tag;

pub const Session = struct {
    vm: *VM,
    gpa: Allocator,
    workspace: revo.lang.Workspace,
    source_acc: std.ArrayList(u8),
    project: revo.lang.Project = .{ .mode = .script, .root = "" },

    pub fn init(vm: *VM, gpa: Allocator, io: ?std.Io) !Session {
        var self = Session{
            .vm = vm,
            .gpa = gpa,
            .workspace = undefined,
            .source_acc = undefined,
            .project = undefined,
        };
        self.project = if (io) |i|
            .detectFromCwd(i, gpa)
        else
            .{ .mode = .script, .root = "" };
        errdefer self.project.deinit(gpa);
        self.workspace = try revo.lang.Workspace.initWithVm(vm, gpa);
        errdefer self.workspace.deinit();
        self.source_acc = try std.ArrayList(u8).initCapacity(gpa, 256);
        errdefer self.source_acc.deinit(gpa);

        return self;
    }

    pub fn deinit(self: *Session) void {
        self.source_acc.deinit(self.gpa);
        self.workspace.deinit();
        self.project.deinit(self.gpa);
    }

    fn clear(self: *Session) void {
        self.source_acc.clearRetainingCapacity();
        self.vm.globals.clearRetainingCapacity();
        self.vm.const_globals.clearRetainingCapacity();
    }

    fn clearSnippet(self: *Session) void {
        self.source_acc.clearRetainingCapacity();
    }

    fn printResult(self: *Session, out: *std.Io.Writer) !void {
        var w = std.Io.Writer.Allocating.init(self.gpa);
        defer w.deinit();
        try self.vm.mainResult().write(&w.writer, self.vm, .debug);
        try out.writeAll(w.written());
        try out.writeAll("\n");
    }

    fn printBuildError(self: *Session, out: *std.Io.Writer, source: []const u8, err: revo.lang.Error) !void {
        var buf = std.Io.Writer.Allocating.init(self.gpa);
        defer buf.deinit();
        try revo.lang.renderError(self.gpa, &buf.writer, .{ .name = "<repl>", .text = source }, err);
        try out.writeAll(buf.written());
        revo.lang.deinitError(self.gpa, err);
    }

    fn printRuntimeFailure(self: *Session, out: *std.Io.Writer, source: []const u8, failure: revo.EvalFailure) !void {
        var buf = std.Io.Writer.Allocating.init(self.gpa);
        defer buf.deinit();
        try failure.render(self.gpa, &buf.writer, source);
        try out.writeAll(buf.written());
    }

    fn runDocBuiltin(self: *Session, out: *std.Io.Writer, builtin_name: []const u8, topic: ?[]const u8) !void {
        const callee = self.vm.getGlobal(builtin_name) orelse {
            try out.print("missing builtin: {s}\n", .{builtin_name});
            return;
        };
        const result = if (topic) |t| blk: {
            const arg = try self.vm.ownDataString(t);
            break :blk self.vm.callFunction(callee, &[_]revo.Data{arg}) catch |err| {
                try out.print("{s} failed: {}\n", .{ builtin_name, err });
                return;
            };
        } else self.vm.callFunction(callee, &[_]revo.Data{}) catch |err| {
            try out.print("{s} failed: {}\n", .{ builtin_name, err });
            return;
        };

        var rendered = std.Io.Writer.Allocating.init(self.gpa);
        defer rendered.deinit();
        try result.write(&rendered.writer, self.vm, .display);
        try out.writeAll(rendered.written());
        try out.writeAll("\n");
    }

    pub fn step(self: *Session, out: *std.Io.Writer, raw_line: []const u8) !bool {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        defer self.vm.runtime.resetDiagArena();

        if (line.len == 0) return true;
        if (std.mem.eql(u8, line, ":q") or std.mem.eql(u8, line, ":quit")) return false;

        if (std.mem.eql(u8, line, ":clear")) {
            self.clear();
            try out.writeAll("session cleared\n");
            return true;
        }

        if (std.mem.eql(u8, line, ":features")) {
            try out.print("isocline={any}, lsp={any}\n", .{ build_options.isocline, build_options.lsp_enabled });
            return true;
        }

        if (std.mem.eql(u8, line, ":h") or std.mem.eql(u8, line, ":help")) {
            try self.runDocBuiltin(out, "help", null);
            return true;
        }

        if (std.mem.startsWith(u8, line, ":help ")) {
            try self.runDocBuiltin(out, "help", std.mem.trim(u8, line[6..], " \t"));
            return true;
        }

        if (std.mem.startsWith(u8, line, ":doc ")) {
            try self.runDocBuiltin(out, "doc", std.mem.trim(u8, line[5..], " \t"));
            return true;
        }

        if (std.mem.eql(u8, line, ":doc")) {
            try self.runDocBuiltin(out, "help", "doc");
            return true;
        }

        if (std.mem.startsWith(u8, line, ":apropos ")) {
            try self.runDocBuiltin(out, "apropos", std.mem.trim(u8, line[9..], " \t"));
            return true;
        }

        if (std.mem.eql(u8, line, ":apropos")) {
            try out.writeAll("usage: :apropos <term>\n");
            return true;
        }

        if (std.mem.eql(u8, line, ":doctest")) {
            try self.runDocBuiltin(out, "doctest", null);
            return true;
        }

        if (std.mem.startsWith(u8, line, ":doctest ")) {
            try self.runDocBuiltin(out, "doctest", std.mem.trim(u8, line[9..], " \t"));
            return true;
        }

        // do null-terminated snippet with trailing newline on the stack when
        // possible; fall back to heap for super long lines
        var snippet_buf = try std.ArrayList(u8).initCapacity(self.gpa, 8);
        defer snippet_buf.deinit(self.gpa);
        try snippet_buf.appendSlice(self.gpa, line);
        try snippet_buf.append(self.gpa, '\n');
        const snippet = snippet_buf.items;

        // try parsing the snippet on its own first to decide whether it is a
        // complete expression or an unfinished fragment like opening of a block
        var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer parse_arena.deinit();

        const parse_ok = switch (revo.lang.parseSourceReport(parse_arena.allocator(), snippet) catch |err| {
            try out.print("parse error: {}\n", .{err});
            return true;
        }) {
            .ok => true,
            .err => false,
        };

        const source = if (parse_ok) snippet else blk: {
            try self.source_acc.appendSlice(self.gpa, line);
            try self.source_acc.append(self.gpa, '\n');
            break :blk self.source_acc.items;
        };

        const file_id = self.workspace.open("<repl>", source) catch |err| {
            try out.print("repl open error: {}\n", .{err});
            return true;
        };

        var analysis = self.workspace.analyzeDetailed(self.gpa, file_id, .{}) catch |err| {
            try out.print("repl build error: {}\n", .{err});
            return true;
        };
        defer analysis.deinit(self.gpa);

        if (analysis.diagnostics) |lang_err| {
            try self.printBuildError(out, source, lang_err);
            analysis.diagnostics = null;
            return true;
        }

        const artifact = analysis.artifact.?;
        analysis.artifact = null;
        defer self.gpa.free(artifact.instructions);
        defer self.gpa.free(artifact.spans);

        self.vm.setProgramDebugInfo(artifact.spans, source, "<repl>") catch {};

        // const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(self.vm.runtime.io, ".", self.gpa);
        // defer self.gpa.free(cwd_path);

        const run_result = revo.module.runCompiledSessionReport(
            self.vm,
            ".",
            artifact.instructions,
        ) catch |err| {
            try out.print("runtime error: {}\n", .{err});
            self.clearSnippet();
            return true;
        };

        switch (run_result) {
            .ok => {
                if (!parse_ok) self.source_acc.clearRetainingCapacity();
                try self.printResult(out);
            },
            .err => |failure| {
                try self.printRuntimeFailure(out, source, failure);
                self.clearSnippet();
            },
        }

        return true;
    }
};

pub fn run(vm: *VM, gpa: Allocator, init: std.process.Init) !void {
    var banner_buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &banner_buffer);
    const writer = &out.interface;

    try writer.print(
        "revo {s} repl -- type :q to exit, :clear to reset session\n",
        .{build_options.version},
    );
    try writer.print("\x1b[0;95m# {s}\x1b[0m\n", .{
        splashText(splashSeed(vm, &banner_buffer, writer)),
    });
    try writer.flush();

    const signal_was_set = build_options.isocline and OS != .wasi;
    if (signal_was_set) _ = signal_c.signal(signal_c.SIGINT, @ptrCast(&sigintHandler));

    if (build_options.isocline) {
        isocline_ctx = IsoclineContext{ .vm = vm, .gpa = gpa };

        var b: [512]u8 = undefined;
        const hist_path = if (std.c.getenv("HOME")) |p|
            try std.fmt.bufPrintZ(&b, "{s}/.revo_history", .{std.mem.span(p)})
        else
            try std.fmt.bufPrintZ(&b, ".revo_history", .{});
        isocline_c.ic_set_history(hist_path.ptr, 1000);

        // lfeatures
        _ = isocline_c.ic_enable_color(true);
        _ = isocline_c.ic_enable_inline_help(true);
        _ = isocline_c.ic_enable_completion_preview(true);
        _ = isocline_c.ic_enable_hint(true);
        isocline_c.ic_set_default_completer(@ptrCast(&isoclineCompleter), null);
        isocline_c.ic_set_default_highlighter(@ptrCast(&isoclineHighlighter), null);

        for (&[_][]const u8{ "keyword", "string", "number", "function", "hash" }) |s| {
            const def = revo.pretty.replStyleDef(s);
            var name_buf: [32]u8 = undefined;
            const s_c = try std.fmt.bufPrintZ(&name_buf, "{s}", .{s});
            _ = isocline_c.ic_style_def(s_c.ptr, def.ptr);
        }
    }

    var session = try Session.init(vm, gpa, init.io);
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
    }

    if (signal_was_set) _ = signal_c.signal(signal_c.SIGINT, @ptrFromInt(0));
    try writer.writeAll("goodbye\n");
    try writer.flush();
}

const TestEnv = struct {
    vm: *revo.VM,
    session: Session,
    out: std.Io.Writer.Allocating,
};

fn initTestEnv(alloc: std.mem.Allocator) !TestEnv {
    const vm = try alloc.create(revo.VM);
    vm.* = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io });
    const session = try Session.init(vm, alloc, std.testing.io);
    const out = std.Io.Writer.Allocating.init(alloc);
    revo.pretty.supports_color = false;
    return TestEnv{ .vm = vm, .session = session, .out = out };
}

test "repl prints results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    try std.testing.expect(try env.session.step(&env.out.writer, "1 + 1"));
    try std.testing.expectEqualStrings("2\n", env.out.written());
}

test "repl handles commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    try env.vm.globals.put(1, revo.Data.new.nil());
    try env.vm.const_globals.put(2, {});
    try env.session.source_acc.appendSlice(std.testing.allocator, "pending");

    try std.testing.expect(try env.session.step(&env.out.writer, ":clear"));
    try std.testing.expectEqual(@as(usize, 0), env.vm.globals.count());
    try std.testing.expectEqual(@as(usize, 0), env.vm.const_globals.count());
    try std.testing.expectEqual(@as(usize, 0), env.session.source_acc.items.len);
    try std.testing.expect(std.mem.indexOf(u8, env.out.written(), "session cleared") != null);
    try std.testing.expect(try env.session.step(&env.out.writer, ":help"));
    try std.testing.expect(!(try env.session.step(&env.out.writer, ":q")));
}

test "repl keeps globals after runtime failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    try std.testing.expect(try env.session.step(&env.out.writer,
        \\ global a = fn(x: int, y: string) "asdf"
    ));

    const before_call = env.out.written().len;
    try std.testing.expect(try env.session.step(&env.out.writer, "a(5, \"hi\")"));
    try std.testing.expect(std.mem.indexOfPos(u8, env.out.written(), before_call, "asdf") != null);
}

test "repl can call a global function later" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    const ok1 = try env.session.step(&env.out.writer, "global f = fn(a, b) a + b");
    try std.testing.expect(ok1);
    const before_call = env.out.written().len;
    const ok2 = try env.session.step(&env.out.writer, "f(1, 3)");
    try std.testing.expect(ok2);
    try std.testing.expect(std.mem.indexOfPos(u8, env.out.written(), before_call, "4\n") != null);
}

// the workspace caches compiled bytecode by FileId; re-opening <repl> with
// new text via change() should invalidate caches
test "repl string methods work on multiple string literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    const ok1 = try env.session.step(&env.out.writer, "\"abc\":trim()");
    try std.testing.expect(ok1);

    const before = env.out.written().len;
    _ = try env.session.step(&env.out.writer, "\"abc\":sub(1,1)");
    // second step should succeed but may error with wrong method name
    try std.testing.expect(std.mem.indexOf(u8, env.out.written()[before..], "error:") == null);
}

// same bug with methods in reverse order
test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    _ = try env.session.step(&env.out.writer, "\"abc\":sub(1,1)");

    const before = env.out.written().len;
    _ = try env.session.step(&env.out.writer, "\"abc\":trim()");
    try std.testing.expect(std.mem.indexOf(u8, env.out.written()[before..], "error:") == null);
}

test "repl multiple string methods in sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    _ = try env.session.step(&env.out.writer, "\"abc\":trim()");
    const before = env.out.written().len;
    _ = try env.session.step(&env.out.writer, "\"abc\":split(\"b\")");
    try std.testing.expect(std.mem.indexOf(u8, env.out.written()[before..], "error:") == null);

    const before2 = env.out.written().len;
    _ = try env.session.step(&env.out.writer, "\"abc\":replace(\"b\", \"d\")");
    try std.testing.expect(std.mem.indexOf(u8, env.out.written()[before2..], "error:") == null);

    const before3 = env.out.written().len;
    _ = try env.session.step(&env.out.writer, "\"abc\":starts_with?(\"a\")");
    try std.testing.expect(std.mem.indexOf(u8, env.out.written()[before3..], "error:") == null);
}
