const std = @import("std");
const revo = @import("revo");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const VM = revo.VM;

const isocline_c = if (builtin.link_libc) @import("isocline") else struct {};

const signal_c = if (build_options.isocline and builtin.link_libc)
    @cImport(@cInclude("signal.h"))
else
    struct {};

const IsoclineContext = struct {
    vm: *VM,
    gpa: Allocator,
    workspace: *revo.lang.Workspace,
    last_file: *?revo.lang.FileId,
    current_input: std.ArrayList(u8),
    cursor_pos: usize,
};

var isocline_ctx: ?IsoclineContext = null;

const splash_texts = [_][]const u8{
    "hi",
    "make your readme .nfo",
    "the moon is flat",
    "green needle",
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
    seed ^= @as(u64, @intFromPtr(&splashSeed)) >> 1;
    var rng = std.Random.SplitMix64.init(seed);
    return @intCast(rng.next());
}

fn isoclineCompleter(cenv: ?*isocline_c.ic_completion_env_t, prefix: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (cenv == null) return;
    const ctx = isocline_ctx orelse return;

    const plen = std.mem.len(prefix);
    const pslice = prefix[0..plen];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const commands = &[_][]const u8{
        ":q",
        ":quit",
        ":features",
        ":h",
        ":outline",
    };
    for (commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, pslice)) {
            var buf: [64]u8 = undefined;
            const cmd_c = std.fmt.bufPrintZ(&buf, "{s}", .{cmd[plen..]}) catch continue;
            _ = isocline_c.ic_add_completion_ex(cenv, cmd_c, cmd_c, null);
        }
    }

    // use workspace completions with stashed input line
    const input_slice = ctx.current_input.items;
    const cursor_pos = ctx.cursor_pos;
    const file_id = ctx.last_file.* orelse return;
    const completions = ctx.workspace.completions(alloc, file_id, input_slice, cursor_pos) catch return;
    for (completions) |item| {
        if (plen > item.label.len) continue;
        var label_buf: [256]u8 = undefined;
        const label_c = std.fmt.bufPrintZ(&label_buf, "{s}", .{item.label[plen..]}) catch continue;

        var detail_buf: [256]u8 = undefined;
        const detail_c: [*c]const u8 = if (item.detail) |d|
            std.fmt.bufPrintZ(&detail_buf, "{s}", .{d}) catch null
        else
            null;
        var doc_buf: [512]u8 = undefined;
        const doc_c: [*c]const u8 = if (item.documentation) |d|
            std.fmt.bufPrintZ(&doc_buf, "{s}", .{d}) catch null
        else
            null;

        _ = isocline_c.ic_add_completion_ex(cenv, label_c, detail_c orelse label_c, doc_c);
    }
}

fn isoclineHighlighter(henv: ?*isocline_c.ic_highlight_env_t, input: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (henv == null) return;
    const input_len = std.mem.len(input);
    if (input_len == 0) return;
    const input_slice = input[0..input_len];

    // stash input for the completer (cursor at end of current input)
    if (isocline_ctx) |*ctx| {
        ctx.current_input.clearRetainingCapacity();
        ctx.current_input.appendSlice(ctx.gpa, input_slice) catch {};
        ctx.cursor_pos = input_len;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = switch (revo.lang.lexReportAt(alloc, input_slice, .{}) catch return) {
        .ok => |t| t,
        .err => {
            isocline_c.ic_highlight_formatted(henv, input, input);
            return;
        },
    };

    const ast_map = revo.lang.Workspace.buildASTSpanMap(alloc, input_slice);

    var fb = std.ArrayList(u8).initCapacity(alloc, input_len + 32) catch return;

    var last: usize = 0;
    for (tokens) |tok| {
        const tstart = tok.start;
        const tend = tok.end;
        if (tend <= tstart) continue;

        if (tstart > last) fb.appendSlice(alloc, input_slice[last..tstart]) catch {};

        const ast_type: ?u32 = if (ast_map) |m| m.get(tstart) else null;

        const style: ?[]const u8 = if (ast_type) |t|
            switch (@as(revo.lang.TokenClass, @enumFromInt(t))) {
                .variable => null,
                .enum_member => "hash",
                else => |e| @tagName(e),
            }
        else if (tok.type.classify()) |cls|
            switch (cls) {
                .variable => null,
                .enum_member => "hash",
                else => |e| @tagName(e),
            }
        else if (tok.type == .ident and revo.lang.Lexer.identIsFunction(input_slice, tok.end))
            "function"
        else
            null;

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
        var stdout = revo.stdout().writer(init.io, &stdout_buffer);
        stdout.interface.writeAll(">> ") catch {};
        stdout.interface.flush() catch {};

        var stdin_buffer: [1024]u8 = undefined;
        var stdin_reader = revo.stdin().reader(init.io, &stdin_buffer);
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
    last_file: ?revo.lang.FileId = null,

    pub fn init(vm: *VM, gpa: Allocator, io: ?std.Io) !Session {
        var workspace = try revo.lang.Workspace.initWithVm(vm, gpa);
        errdefer workspace.deinit();
        const source_acc = try std.ArrayList(u8).initCapacity(gpa, 256);
        errdefer source_acc.deinit(gpa);
        var self = Session{
            .vm = vm,
            .gpa = gpa,
            .workspace = workspace,
            .source_acc = source_acc,
        };
        self.project = if (io) |i|
            .detectFromCwd(i, gpa)
        else
            .{ .mode = .script, .root = "" };
        errdefer self.project.deinit(gpa);

        return self;
    }

    pub fn deinit(self: *Session) void {
        self.source_acc.deinit(self.gpa);
        self.workspace.deinit();
        self.project.deinit(self.gpa);
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

    fn printOutline(self: *Session, out: *std.Io.Writer) !void {
        const fid = self.last_file orelse {
            try out.writeAll("no code yet\n");
            return;
        };
        const syms = try self.workspace.documentSymbols(self.gpa, fid, .{});
        defer {
            for (syms) |*s| {
                self.gpa.free(s.name);
                if (s.type_name) |*ti| revo.lang.types.deinitType(ti, self.gpa);
            }
            self.gpa.free(syms);
        }
        if (syms.len == 0) {
            try out.writeAll("no symbols\n");
            return;
        }
        for (syms) |s| {
            const kind: []const u8 = switch (s.kind) {
                .binding => "let",
                .function => "fn",
                .type_alias => "alias",
                .param => "param",
                .macro => "macro",
            };
            try out.print("{s} {s} : {d}\n", .{ kind, s.name, s.range.start.line });
        }
    }

    /// :h <name> - session decls first, then stdlib
    fn helpTopic(self: *Session, out: *std.Io.Writer, name: []const u8) !bool {
        if (self.last_file) |fid| {
            if (try self.workspace.hoverByName(self.gpa, fid, name)) |text| {
                defer self.gpa.free(text);
                try out.writeAll(text);
                try out.writeAll("\n");
                return true;
            }
        }
        if (revo.std_lib.api.find(name)) |spec| {
            var buf = std.Io.Writer.Allocating.init(self.gpa);
            defer buf.deinit();
            try revo.std_lib.api.renderSignature(&buf.writer, spec.*);
            try out.writeAll(buf.written());
            try out.writeAll("\n");
            if (spec.doc.len > 0) {
                try out.writeAll(spec.doc);
                try out.writeAll("\n");
            }
            return true;
        }
        return false;
    }

    pub fn step(self: *Session, out: *std.Io.Writer, raw_line: []const u8) !bool {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        defer self.vm.runtime.resetDiagArena();

        if (line.len == 0) return true;
        if (std.mem.eql(u8, line, ":q") or std.mem.eql(u8, line, ":quit")) return false;

        if (std.mem.eql(u8, line, ":features")) {
            try out.print("isocline={any}, lsp={any}\n", .{ build_options.isocline, build_options.lsp_enabled });
            return true;
        }

        if (std.mem.eql(u8, line, ":h")) {
            try out.writeAll("usage: :h <name>\n");
            return true;
        }

        if (std.mem.startsWith(u8, line, ":h ")) {
            const topic = std.mem.trim(u8, line[3..], " \t");
            if (!try self.helpTopic(out, topic)) {
                try out.print("no docs for {s}\n", .{topic});
            }
            return true;
        }

        if (std.mem.eql(u8, line, ":outline")) {
            try self.printOutline(out);
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

        const file_id = self.workspace.open("<repl>", source, .{}) catch |err| {
            try out.print("repl open error: {}\n", .{err});
            return true;
        };
        self.last_file = file_id;

        var analysis = self.workspace.analyzeDetailed(self.gpa, file_id, .{}) catch |err| {
            try out.print("repl build error: {}\n", .{err});
            return true;
        };
        defer analysis.deinit(self.gpa);

        if (analysis.diagnostics) |lang_err| {
            try self.printBuildError(out, source, lang_err);
            analysis.diagnostics = null;
            self.clearSnippet();
            return true;
        }

        const artifact = analysis.artifact.?;
        analysis.artifact = null;
        defer self.gpa.free(artifact.instructions);
        defer self.gpa.free(artifact.spans);

        self.vm.setProgramDebugInfo(artifact.spans, source, "<repl>") catch {};

        const run_result = revo.module.runCompiledModuleReport(
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
    var out = revo.stdout().writer(init.io, &banner_buffer);
    const writer = &out.interface;

    const target_triple = try builtin.target.linuxTriple(gpa);
    try writer.print(
        "revo {s} repl ({s} for {s})\n> :q to exit, :h <name> for docs, <C-j> to start new line\n",
        .{ build_options.version, build_options.git_commit, target_triple },
    );
    gpa.free(target_triple);
    try writer.print("\x1b[0;95m# {s}\x1b[0m\n", .{
        splashText(splashSeed(vm, &banner_buffer, writer)),
    });
    try writer.flush();

    const signal_was_set = build_options.isocline and OS != .wasi;
    if (signal_was_set) _ = signal_c.signal(signal_c.SIGINT, @ptrCast(&sigintHandler));

    var session = try Session.init(vm, gpa, init.io);
    defer session.deinit();

    if (build_options.isocline) {
        isocline_ctx = IsoclineContext{
            .vm = vm,
            .gpa = gpa,
            .workspace = &session.workspace,
            .last_file = &session.last_file,
            .current_input = try std.ArrayList(u8).initCapacity(gpa, 256),
            .cursor_pos = 0,
        };

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

    defer if (build_options.isocline) isocline_ctx.?.current_input.deinit(gpa);

    while (true) {
        if (sigint_received.load(.seq_cst)) {
            sigint_received.store(false, .seq_cst);
            try writer.writeAll("\n");
            try writer.flush();
            session.clearSnippet();
            session.last_file = null;
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
    vm.* = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    const session = try Session.init(vm, alloc, std.testing.io);
    const out = std.Io.Writer.Allocating.init(alloc);
    revo.pretty.supports_color = false;
    return TestEnv{ .vm = vm, .session = session, .out = out };
}

// a __index metamethod that parks (recv on an empty channel) must land its
// result in the dispatch instruction's result register after resume, not the
// synthetic host-call frame's register
test "repl parked metamethod resumes with correct result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    try std.testing.expect(try env.session.step(&env.out.writer,
        \\ const ch = chan()
        \\ spawn fn() send(ch, 42)
        \\ const t = set_meta({}, { __index = fn(_self, k) recv(ch) })
        \\ t.foo
    ));

    try std.testing.expect(std.mem.find(u8, env.out.written(), "42") != null);
}

// closing a socket while a fiber is parked on recv must wake that fiber with
// an error instead of dispatching on_ready against the freed SocketEntry
test "repl closing a socket wakes a parked recv with SocketClosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    try std.testing.expect(try env.session.step(&env.out.writer,
        \\ const srv = (net.listen(0))?
        \\ const port = srv.port
        \\ const client = (net.connect("127.0.0.1", port))?
        \\ const results = chan()
        \\ spawn fn() do
        \\   const r = client:recv({ mode = :read_some, max_bytes = 1024 })
        \\   send(results, r)
        \\ end
        \\ sleep(5)
        \\ client:close()
        \\ recv(results)
    ));

    try std.testing.expect(std.mem.find(u8, env.out.written(), ":SocketClosed") != null);
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

    try std.testing.expect(try env.session.step(&env.out.writer, ":features"));
    try std.testing.expect(std.mem.find(u8, env.out.written(), "isocline=") != null);
    env.out.clearRetainingCapacity();

    try std.testing.expect(try env.session.step(&env.out.writer, ":h"));
    try std.testing.expect(std.mem.find(u8, env.out.written(), "usage: :h <name>") != null);
    try std.testing.expect(!(try env.session.step(&env.out.writer, ":q")));
}

test "repl :h shows docs like hover" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    _ = try env.session.step(&env.out.writer,
        \\ #* asdf *#
        \\ global hi = fn() 5
    );
    env.out.clearRetainingCapacity();

    _ = try env.session.step(&env.out.writer, ":h hi");
    const hi_help = env.out.written();
    try std.testing.expect(std.mem.find(u8, hi_help, "fn hi()") != null);
    try std.testing.expect(std.mem.find(u8, hi_help, "asdf") != null);
}

test "repl :h falls back to stdlib docs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    _ = try env.session.step(&env.out.writer, ":h print");
    const help = env.out.written();
    try std.testing.expect(std.mem.find(u8, help, "print(") != null);
    try std.testing.expect(std.mem.find(u8, help, "prints values to stdout") != null);
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
    try std.testing.expect(std.mem.findPos(u8, env.out.written(), before_call, "asdf") != null);
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
    try std.testing.expect(std.mem.findPos(u8, env.out.written(), before_call, "4\n") != null);
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
    try std.testing.expect(std.mem.find(u8, env.out.written()[before..], "error:") == null);
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
    try std.testing.expect(std.mem.find(u8, env.out.written()[before..], "error:") == null);
}

test "repl multiple string methods in sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    _ = try env.session.step(&env.out.writer, "\"abc\":trim()");
    const before = env.out.written().len;
    _ = try env.session.step(&env.out.writer, "\"abc\":split(\"b\")");
    try std.testing.expect(std.mem.find(u8, env.out.written()[before..], "error:") == null);

    const before2 = env.out.written().len;
    _ = try env.session.step(&env.out.writer, "\"abc\":replace(\"b\", \"d\")");
    try std.testing.expect(std.mem.find(u8, env.out.written()[before2..], "error:") == null);

    const before3 = env.out.written().len;
    _ = try env.session.step(&env.out.writer, "\"abc\":starts_with?(\"a\")");
    try std.testing.expect(std.mem.find(u8, env.out.written()[before3..], "error:") == null);
}

test "global declared in one compilation can be reassigned in another" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = try initTestEnv(alloc);

    _ = try env.session.step(&env.out.writer, "global test1 = 123");

    const before = env.out.written().len;
    _ = try env.session.step(&env.out.writer, "test1 = 789");
    try std.testing.expect(std.mem.find(u8, env.out.written()[before..], "error:") == null);
}
