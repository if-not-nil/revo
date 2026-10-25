const std = @import("std");
const Allocator = std.mem.Allocator;
const build_opts = @import("build_options");
const lsp_enabled = build_opts.lsp_enabled;

const revo = @import("revo");
const docgen = revo.lang.docgen;
const Bytecode = revo.lang.Bytecode;
const VM = revo.VM;
const term = revo.term;

const ap = revo.argparse;
const repl = @import("repl.zig");

const SYNOPSIS =
    \\usage: revo [options] [script [args...]]
    \\       revo <command> [options]
    \\
;

const EXAMPLES =
    \\
    \\if the first argument is a command that exists, it gets ran;
    \\otherwise, it's treated as a script path
    \\
    \\examples:
    \\  revo                              start repl
    \\  revo script.rv                    run script
    \\  revo compile script.rv            compile script
    \\  revo compile script.rv out.rvo    compile script with custom output path
    \\  revo -e "1 + 2"                   run inline code
    \\  revo -e "1 + 2" -i                run inline code and enter REPL
    \\  revo bench script.rv              run with timing stats
    \\
++ (if (revo.vm.perf.enabled)
    \\  revo       --perf script.rv       run with VM perf counters (you have -Dperf enabled)
    \\  revo bench --perf script.rv       bench with VM perf counters (you have -Dperf enabled)
    \\
else
    "") ++
    \\  revo dis script.rv                show bytecode disassembly
    \\       doc script.rv                print extracted docs as markdown
    \\       doc --html src/baselib/iface     render the baselib reference as html
    \\       doc --html --splice src/baselib/iface < std.md > std.new   splice into a doc page
    \\
    \\  revo fmt                          format every .rv under the pwd
    \\       fmt script.rv dir/           format that in place
    \\       fmt --check .                list files whose formatting differs
    \\       fmt --diff .                 print a diff of the changes
    \\       fmt - < script.rv            format stdin to stdout
    \\
++ (if (lsp_enabled)
    \\  revo lsp                          start the language server
    \\
else
    "") ++
    \\  revo repl                         start repl explicitly
    \\  revo lsp.rv                       run a script literally named lsp.rv
    \\
;

/// argparse just cant do this
fn usageText(allocator: Allocator, args: []const ap.Arg, commands: []const ap.Command) ![]const u8 {
    const auto = try ap.usage(allocator, args, commands);
    defer allocator.free(auto);
    return try allocator.print("{s}{s}{s}", .{ SYNOPSIS, auto, EXAMPLES });
}

const ExecutionMode = enum { run, repl, bench, disassemble, compile, doc, lsp, format };

const DocMode = enum { markdown, html };

const Config = struct {
    mode: ExecutionMode = .run,
    doc_format: DocMode = .markdown,
    inline_code: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    interactive: bool = false,
    test_mode: bool = false,
    bench_iters: u32 = 1,
    perf: bool = false,
    echo_last: ?revo.Value.PrintMode = null,
    force_splice: bool = false,
    check: bool = false,
    diff: bool = false,
    threads: usize = 1,
    argv: []const [:0]const u8 = &.{},
};

pub fn main(provided_init: std.process.Init) void {
    var init = provided_init;

    if (build_opts.mimalloc) init.gpa = @import("mimalloc").mim_allocator;

    runMain(init) catch |x| switch (x) {
        error.VmInitError,
        error.InsufficientArgs,
        error.InvalidArgs,
        error.UnknownCommand,
        error.CompilationError,
        error.FileError,
        error.FormatNeeded,
        => std.process.exit(1),
        error.HelpRequested,
        error.VersionRequested,
        => {},
        else => |err| {
            var stderr_buf: [256]u8 = undefined;
            var stderr = revo.stderr().writer(init.io, &stderr_buf);
            term.printError(&stderr.interface, hostColor(init), "{s}", .{@errorName(err)}) catch return;
            std.process.exit(1);
        },
    };
}

fn handleSource(
    init: std.process.Init,
    gpa: Allocator,
    arena: Allocator,
    name: []const u8,
    source: []const u8,
    config: Config,
) !void {
    switch (config.mode) {
        .run => try runSource(init, gpa, name, source, config),
        .bench => try benchSource(init, gpa, name, source, config),
        .compile => try compileToBytecode(init, gpa, arena, name, source, config),
        .doc => unreachable,
        .disassemble => {
            var vm = try initVM(init, gpa, config.argv, config.threads);
            defer vm.deinit();
            const bytecode = try compileSource(init, &vm, gpa, name, source, config.test_mode);
            defer gpa.free(bytecode.instructions);
            defer gpa.free(bytecode.spans);
            try revo.vm.disasm.printDisassembly(&vm, bytecode, source);
        },
        .repl, .lsp, .format => unreachable,
    }
}

fn runMain(init: std.process.Init) !void {
    var arena_instance = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try init.minimal.args.toSlice(arena);

    // no args: piped stdin or interactive repl
    if (args.len < 2) {
        const source = try readStdin(init, arena);
        if (source) |s| {
            var vm = try initVM(init, init.gpa, &.{args[0]}, 1);
            defer vm.deinit();
            try revo.baselib.populateArgv(&vm);
            try runSource(init, init.gpa, "<stdin>", s, .{});
            return;
        }
        var vm = try initVM(init, init.gpa, &.{args[0]}, 1);
        defer vm.deinit();
        try revo.baselib.populateArgv(&vm);
        try repl.run(&vm, init.gpa, init);
        return;
    }

    const config = try parseArgs(init, args);

    // early-return modes
    if (config.mode == .repl) {
        var vm = try initVM(init, init.gpa, config.argv, config.threads);
        defer vm.deinit();
        try revo.baselib.populateArgv(&vm);
        return try repl.run(&vm, init.gpa, init);
    }
    if (config.mode == .lsp) {
        var project = revo.lang.Project.detectFromCwd(init.io, init.gpa);
        defer project.deinit(init.gpa);
        return try @import("lsp_main").runLsp(init.gpa, init.io, project.mode, project.root);
    }
    if (config.mode == .doc) {
        return try docgen.Cli.run(init, init.gpa, arena, config.script_path, config.doc_format == .html, config.force_splice);
    }
    if (config.mode == .format) {
        return try formatPaths(init, init.gpa, arena, config.argv, config.check, config.diff);
    }

    // script path or stdin
    if (config.script_path) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try runFromStdin(init, init.gpa, arena, config);
        } else {
            const source = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, std.Io.Limit.unlimited) catch |err| {
                printError(init, "{s} '{s}'", .{ @errorName(err), path });
                return error.FileError;
            };
            if (std.mem.endsWith(u8, path, ".rvo")) {
                switch (config.mode) {
                    .run => try runBytecodeFile(init, init.gpa, path, source, config),
                    .bench => try benchBytecodeFile(init, init.gpa, path, source, config),
                    .disassemble => {
                        var vm = try initVM(init, init.gpa, config.argv, config.threads);
                        defer vm.deinit();
                        var deserialized = revo.bytecode.deserialize(&vm, source, init.gpa) catch |err| {
                            printError(init, "deserializing bytecode - {}", .{err});
                            return error.CompilationError;
                        };
                        defer deserialized.deinit();
                        try revo.vm.disasm.printDisassembly(&vm, .{
                            .instructions = deserialized.instructions,
                            .spans = deserialized.spans,
                        }, "");
                    },
                    .compile => {
                        printError(init, "cannot compile bytecode files", .{});
                        return error.InvalidArgs;
                    },
                    .doc => {
                        printError(init, "cannot extract docs from bytecode files", .{});
                        return error.InvalidArgs;
                    },
                    .repl, .lsp, .format => unreachable,
                }
            } else {
                try handleSource(init, init.gpa, arena, path, source, config);
            }
        }
        if (!config.interactive) return;
    } else {
        // no script path: check for piped stdin
        // -e owns the program, piped stdin stays available for input()
        if (config.inline_code == null) {
            try runFromStdin(init, init.gpa, arena, config);
            if (!config.interactive) return;
        }
    }

    if (config.inline_code) |code| {
        try runInlineCode(init, init.gpa, code, config);
        if (!config.interactive and config.script_path == null) return;
    }

    var vm = try initVM(init, init.gpa, config.argv, config.threads);
    defer vm.deinit();
    try revo.baselib.populateArgv(&vm);
    try repl.run(&vm, init.gpa, init);
}

/// fmt's data output (file lists, diffs) written to stdout, like gofmt
fn printData(init: std.process.Init, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var out = revo.stdout().writer(init.io, &buf);
    try out.interface.print(fmt, args);
    try out.flush();
}

fn printError(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    term.printError(&buf.writer, hostColor(init), fmt, args) catch return;
    std.debug.print("{s}", .{buf.written()});
}

fn printSuccess(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    term.printSuccess(&buf.writer, hostColor(init), fmt, args) catch return;
    std.debug.print("{s}", .{buf.written()});
}

fn readStdin(init: std.process.Init, arena: Allocator) !?[]const u8 {
    const stdin_file = revo.stdin();
    if (try stdin_file.isTty(init.io)) return null;
    return std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "/dev/stdin",
        arena,
        std.Io.Limit.unlimited,
    ) catch |err| {
        printError(init, "reading stdin - {}", .{err});
        return error.FileError;
    };
}

fn runFromStdin(init: std.process.Init, gpa: Allocator, arena: Allocator, config: Config) !void {
    const source = (try readStdin(init, arena)) orelse return;
    if (std.mem.startsWith(u8, source, &revo.bytecode.MAGIC)) {
        try runBytecodeFile(init, gpa, "<stdin>", source, config);
    } else {
        try handleSource(init, gpa, arena, "<stdin>", source, config);
    }
}

var cached_color: ?bool = null;
fn hostColor(init: std.process.Init) bool {
    if (cached_color) |c| return c;
    const c = term.isColorSupported(init.environ_map, init.io);
    cached_color = c;
    return c;
}

fn initVM(init: std.process.Init, gpa: Allocator, argv: []const [:0]const u8, threads: usize) !VM {
    return VM.init(.{
        .alloc = gpa,
        .io = init.io,
        .argv = argv,
        .diag_alloc = gpa,
        .threads = threads,
        .supports_color = hostColor(init),
    }) catch |err| {
        printError(init, "initializing vm - {}", .{err});
        return error.VmInitError;
    };
}

fn compileSource(
    init: std.process.Init,
    vm: *VM,
    gpa: Allocator,
    source_name: []const u8,
    source_text: []const u8,
    test_mode: bool,
) !Bytecode {
    var ws = try revo.lang.Workspace.initWithVm(vm, gpa);
    defer ws.deinit();

    var project = revo.lang.Project.detect(source_name, init.io, gpa);
    defer project.deinit(gpa);

    if (project.mode == .project and project.root.len > 0)
        vm.project_root = try gpa.dupe(u8, project.root);

    const file_id = try project.open(&ws, source_name, source_text);
    var analysis = ws.analyzeDetailed(gpa, file_id, .{ .test_mode = test_mode, .mode = project.mode }) catch |err| {
        printError(init, "compilation - {}", .{err});
        return error.CompilationError;
    };
    defer analysis.deinit(gpa);

    if (analysis.diagnostics) |lang_err| {
        revo.printBuildError(gpa, .{ .name = source_name, .text = source_text }, lang_err, hostColor(init));
        analysis.diagnostics = null;
        vm.runtime.resetDiagArena();
        return error.CompilationError;
    }

    if (analysis.warnings) |w| {
        revo.printBuildWarning(gpa, .{ .name = source_name, .text = source_text }, w, hostColor(init));
    }

    const bytecode = analysis.bytecode.?;
    analysis.bytecode = null;
    return bytecode;
}

fn printResult(vm: *VM, mode: revo.Value.PrintMode) !void {
    var res = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer res.deinit();
    vm.mainResult().write(&res.writer, vm, mode, vm.runtime.supports_color) catch return;
    std.debug.print("{s}\n", .{res.written()});
}

fn runBytecode(
    init: std.process.Init,
    gpa: Allocator,
    vm: *VM,
    name: []const u8,
    bytecode: Bytecode,
    source: []const u8,
    echo_last: ?revo.Value.PrintMode,
    collect_perf: bool,
) !void {
    try vm.setProgramDebugInfo(bytecode.spans, source, name);

    if (comptime revo.vm.perf.enabled) {
        if (collect_perf) {
            vm.resetPerf();
            vm.enablePerf();
        }
    }

    const run_result = try revo.run.runBytecodeReport(vm, name, bytecode.instructions);

    if (comptime revo.vm.perf.enabled) {
        if (collect_perf) {
            vm.disablePerf();
            revo.vm.perf.printReport(&vm.perf);
        }
    }

    switch (run_result) {
        .ok => if (echo_last) |mode| try printResult(vm, mode),
        .err => |failure| {
            revo.printRunError(gpa, source, failure, hostColor(init));
            vm.runtime.resetDiagArena();
        },
    }
}

fn validBenchIters(remainder: []const u8) bool {
    if (remainder.len == 0) return true;
    _ = std.fmt.parseUnsigned(u32, remainder, 10) catch return false;
    return true;
}

/// revo --options-go-here [subcommand/script name] --rest-goes-to-script
fn parseArgs(init: std.process.Init, args: []const [:0]const u8) !Config {
    const allocator = init.arena.allocator();
    var config: Config = .{};
    var leftover: std.ArrayList([:0]const u8) = .empty;

    // no im not putting these into helpers
    var arg_list = [_]ap.Arg{
        .{ .name = "e", .short = 'e', .kind = .string, .description = "run code" },
        .{ .name = "interactive", .short = 'i', .kind = .boolean, .description = "enter repl after executing" },
        .{ .name = "plain", .short = 'd', .kind = .boolean, .description = "output the program's result in plain mode" },
        .{ .name = "debug", .short = 'D', .kind = .boolean, .description = "output the program's result in debug mode" },
        .{ .name = "pretty", .short = 'p', .kind = .boolean, .description = "output the program's result in pretty mode" },
        .{ .name = "test", .kind = .boolean, .description = "run with test blocks" },
        .{ .name = "html", .kind = .boolean, .description = "render as html instead of markdown (doc)" },
        .{ .name = "splice", .kind = .boolean, .description = "splice output into markdown piped on stdin (doc)" },
        .{ .name = "check", .kind = .boolean, .description = "list files whose formatting differs, dont write (fmt)" },
        .{ .name = "diff", .kind = .boolean, .description = "print a unified diff, dont write (fmt)" },
        .{ .name = "threads", .kind = .string, .description = "worker threads (default 1, single-threaded without async)" },
        .{ .name = "help", .short = 'h', .kind = .boolean, .description = "show this help message" },
        // terminal positional:
        //   stops flag-parsing, goes to passthru argv
        //   output path (compile mode) is handled below by hand
        .{ .name = "script", .kind = .positional, .terminal = true, .passthrough = true },
    } ++ if (comptime revo.vm.perf.enabled) [_]ap.Arg{
        // only exists in -Dperf builds; otherwise parses as unknown
        .{ .name = "perf", .kind = .boolean, .description = "collect and print VM perf counters (needs -Dperf)" },
    } else [_]ap.Arg{};

    var commands_buf: [8]ap.Command = undefined;
    var n: usize = 0;
    inline for (&[_]struct { name: []const u8, prefix: bool, has_validate: bool, desc: []const u8 }{
        .{ .name = "compile", .prefix = false, .has_validate = false, .desc = "compile script to bytecode instead of running" },
        .{ .name = "repl", .prefix = false, .has_validate = false, .desc = "start repl (default with no args)" },
        .{ .name = "lsp", .prefix = false, .has_validate = false, .desc = "start the lsp" },
        .{ .name = "dis", .prefix = false, .has_validate = false, .desc = "show bytecode disassembly instead of running" },
        .{ .name = "doc", .prefix = false, .has_validate = false, .desc = "extract doc comments from a file, dir, or the pwd workspace" },
        .{ .name = "fmt", .prefix = false, .has_validate = false, .desc = "format .rv files in place, like go fmt" },
        .{ .name = "version", .prefix = false, .has_validate = false, .desc = "show version and build info" },
        .{ .name = "bench", .prefix = true, .has_validate = true, .desc = "run N iterations with timing stats ([n] iterations, 1 if not specified)" },
    }) |cmd_def| {
        if (comptime lsp_enabled or cmd_def.name[0] != 'l' or cmd_def.name[1] != 's' or cmd_def.name[2] != 'p') {
            commands_buf[n] = .{
                .name = cmd_def.name,
                .prefix = cmd_def.prefix,
                .validate = if (cmd_def.has_validate) validBenchIters else null,
                .description = cmd_def.desc,
            };
            n += 1;
        }
    }
    const commands = commands_buf[0..n];

    var res = ap.Result{ .args = &arg_list, .commands = commands, .leftover = &leftover };

    ap.parse(allocator, args[1..], &res) catch |err| {
        if (ap.cliArg(&arg_list, "help").enabled) { // help always wins
            const text = try usageText(allocator, &arg_list, commands);
            defer allocator.free(text);
            std.debug.print("{s}\n", .{text});
            return error.HelpRequested;
        }
        switch (err) {
            error.MissingValue => {
                printError(init, "{s} requires an argument", .{res.err_token.?});
                return error.InsufficientArgs;
            },
            error.UnexpectedLongArg, error.UnexpectedShortArg => {
                printError(init, "unknown option '{s}'", .{res.err_token.?});
                const text = try usageText(allocator, &arg_list, commands);
                defer allocator.free(text);
                std.debug.print("{s}\n", .{text});
                return error.UnknownCommand;
            },
            else => return err,
        }
    };

    if (ap.cliArg(&arg_list, "help").enabled) { // help
        const text = try usageText(allocator, &arg_list, commands);
        defer allocator.free(text);
        std.debug.print("{s}\n", .{text});
        return error.HelpRequested;
    }

    // map commands to execution mode
    for (commands) |cmd| {
        if (cmd.triggered) {
            if (std.mem.eql(u8, cmd.name, "version")) {
                std.debug.print("revo {s} ({s})\n", .{ build_opts.version, build_opts.git_commit });
                return error.VersionRequested;
            }
            if (std.mem.eql(u8, cmd.name, "compile")) config.mode = .compile;
            if (std.mem.eql(u8, cmd.name, "repl")) config.mode = .repl;
            if (std.mem.eql(u8, cmd.name, "lsp")) config.mode = .lsp;
            if (std.mem.eql(u8, cmd.name, "dis")) config.mode = .disassemble;
            if (std.mem.eql(u8, cmd.name, "doc")) config.mode = .doc;
            if (std.mem.eql(u8, cmd.name, "fmt")) config.mode = .format;
            if (std.mem.eql(u8, cmd.name, "bench")) {
                config.mode = .bench;
                config.bench_iters = if (cmd.value.len == 0) 1 else std.fmt.parseUnsigned(u32, cmd.value, 10) catch 1;
            }
        }
    }

    // map flags
    config.interactive = ap.cliArg(&arg_list, "interactive").enabled; // -i
    config.test_mode = ap.cliArg(&arg_list, "test").enabled; // --test
    config.force_splice = ap.cliArg(&arg_list, "splice").enabled; // --splice
    config.check = ap.cliArg(&arg_list, "check").enabled; // --check
    config.diff = ap.cliArg(&arg_list, "diff").enabled; // --diff

    if (comptime revo.vm.perf.enabled) {
        config.perf = ap.cliArg(&arg_list, "perf").enabled; // --perf
    }
    if (ap.cliArg(&arg_list, "plain").enabled) config.echo_last = .plain; // -d
    if (ap.cliArg(&arg_list, "debug").enabled) config.echo_last = .debug; // -D
    if (ap.cliArg(&arg_list, "pretty").enabled) config.echo_last = .pretty; // -P
    if (ap.cliArg(&arg_list, "html").enabled and config.mode == .doc) config.doc_format = .html; // --html

    // -e always gets the script slot
    if (ap.cliArg(&arg_list, "e").value) |code| { // -e
        config.inline_code = code;
        try leftover.insert(allocator, 0, args[0]);
    } else {
        config.script_path = ap.cliArg(&arg_list, "script").value; // script positional
    }

    if (ap.cliArg(&arg_list, "threads").value) |v| { // --threads
        config.threads = std.fmt.parseUnsigned(usize, v, 10) catch {
            printError(init, "--threads requires a positive integer, got '{s}'", .{v});
            return error.InvalidArgs;
        };
        if (config.threads == 0) config.threads = 1;
        if (config.threads > 1 and !revo.can_async)
            std.debug.print("warning: --threads={d} not supported on this platform, running single-threaded\n", .{config.threads});
    }

    // compile mode: steal the second positional as output path
    if (config.mode == .compile and leftover.items.len >= 2) {
        const candidate = leftover.items[1];
        if (!std.mem.startsWith(u8, candidate, "-")) {
            config.output_path = candidate;
            _ = leftover.orderedRemove(1);
        }
    }

    config.argv = try leftover.toOwnedSlice(allocator);
    return config;
}

fn runInlineCode(init: std.process.Init, gpa: Allocator, code: []const u8, config: Config) !void {
    var vm = try initVM(init, gpa, config.argv, config.threads);
    defer vm.deinit();

    const bytecode = try compileSource(init, &vm, gpa, "<inline>", code, config.test_mode);
    defer gpa.free(bytecode.instructions);
    defer gpa.free(bytecode.spans);

    try revo.baselib.populateArgv(&vm);
    try runBytecode(init, gpa, &vm, "<inline>", bytecode, code, config.echo_last, config.perf);
}

fn runSource(
    init: std.process.Init,
    gpa: Allocator,
    path: []const u8,
    source: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv, config.threads);
    defer vm.deinit();

    const bytecode = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(bytecode.instructions);
    defer gpa.free(bytecode.spans);

    try vm.setProgramDebugInfo(bytecode.spans, source, path);

    try revo.baselib.populateArgv(&vm);
    try runBytecode(init, gpa, &vm, path, bytecode, source, config.echo_last, config.perf);
}

fn runBytecodeFile(
    init: std.process.Init,
    gpa: Allocator,
    path: []const u8,
    bytecode_data: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv, config.threads);
    defer vm.deinit();

    var deserialized = revo.bytecode.deserialize(&vm, bytecode_data, gpa) catch |err| {
        printError(init, "deserializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer deserialized.deinit();

    vm.setProgramDebugInfo(deserialized.spans, "", path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    try revo.baselib.populateArgv(&vm);
    try runBytecode(
        init,
        gpa,
        &vm,
        path,
        .{ .spans = deserialized.spans, .instructions = deserialized.instructions },
        "",
        config.echo_last,
        config.perf,
    );
}

fn benchBytecode(
    init: std.process.Init,
    gpa: Allocator,
    vm: *VM,
    name: []const u8,
    bytecode: Bytecode,
    source: []const u8,
    iters: u32,
    echo_last: ?revo.Value.PrintMode,
    collect_perf: bool,
) !void {
    var times = try std.ArrayList(std.Io.Duration).initCapacity(gpa, iters);
    defer times.deinit(gpa);

    var last_result: ?revo.RunResult = null;

    if (comptime revo.vm.perf.enabled) {
        if (collect_perf) {
            vm.resetPerf();
            vm.enablePerf();
        }
    }

    for (0..iters) |_| {
        const t_start = std.Io.Timestamp.now(init.io, .cpu_process);
        const run_result = try revo.run.runBytecodeReport(vm, name, bytecode.instructions);
        const t_end = std.Io.Timestamp.now(init.io, .cpu_process);
        times.appendAssumeCapacity(t_start.durationTo(t_end));
        last_result = run_result;

        if (run_result == .err) {
            printRuntimeFailure(init, run_result.err, source);
            vm.runtime.resetDiagArena();
        }
    }

    if (comptime revo.vm.perf.enabled) {
        if (collect_perf) vm.disablePerf();
    }

    if (echo_last) |mode| {
        if (last_result) |result| switch (result) {
            .ok => try printResult(vm, mode),
            .err => |failure| {
                printRuntimeFailure(init, failure, source);
                vm.runtime.resetDiagArena();
            },
        };
    }

    revo.vm.disasm.printBenchStats(times.items);

    if (comptime revo.vm.perf.enabled) {
        if (collect_perf) revo.vm.perf.printReport(&vm.perf);
    }
}

fn benchSource(init: std.process.Init, gpa: Allocator, path: []const u8, source: []const u8, config: Config) !void {
    var vm = try initVM(init, gpa, config.argv, config.threads);
    defer vm.deinit();

    const bytecode = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(bytecode.instructions);
    defer gpa.free(bytecode.spans);

    vm.setProgramDebugInfo(bytecode.spans, source, path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    try revo.baselib.populateArgv(&vm);
    try benchBytecode(init, gpa, &vm, path, bytecode, source, config.bench_iters, config.echo_last, config.perf);
}

fn benchBytecodeFile(
    init: std.process.Init,
    gpa: Allocator,
    path: []const u8,
    bytecode_data: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv, config.threads);
    defer vm.deinit();

    var deserialized = revo.bytecode.deserialize(&vm, bytecode_data, gpa) catch |err| {
        printError(init, "deserializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer deserialized.deinit();

    vm.setProgramDebugInfo(deserialized.spans, "", path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    try revo.baselib.populateArgv(&vm);
    try benchBytecode(
        init,
        gpa,
        &vm,
        path,
        .{ .instructions = deserialized.instructions, .spans = deserialized.spans },
        "",
        config.bench_iters,
        config.echo_last,
        config.perf,
    );
}

fn compileToBytecode(
    init: std.process.Init,
    gpa: Allocator,
    arena: Allocator,
    path: []const u8,
    source: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv, config.threads);
    defer vm.deinit();

    const compiled = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(compiled.instructions);
    defer gpa.free(compiled.spans);

    const bytecode = revo.bytecode.serialize(&vm, compiled, gpa) catch |err| {
        printError(init, "serializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer gpa.free(bytecode);

    const output_path: []const u8 = if (config.output_path) |provided|
        provided
    else blk: {
        if (std.mem.endsWith(u8, path, ".rv")) {
            const base = path[0 .. path.len - 3];
            break :blk arena.print("{s}.rvo", .{base}) catch {
                printError(init, "output path allocation failed", .{});
                return error.FileError;
            };
        } else {
            break :blk arena.print("{s}.rvo", .{path}) catch {
                printError(init, "output path allocation failed", .{});
                return error.FileError;
            };
        }
    };

    std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = bytecode,
    }) catch |err| {
        printError(init, "writing bytecode file '{s}' - {}", .{ output_path, err });
        return error.FileError;
    };

    printSuccess(init, "compiled to {s}", .{output_path});
}

fn isDir(init: std.process.Init, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(init.io, path, .{}) catch return false;
    dir.close(init.io);
    return true;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// recursive `.rv` collection
/// skip hidden and `_`-prefixed dirs: caches and vendored trees
fn collectRvFiles(
    init: std.process.Init,
    arena: Allocator,
    dir: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const open_dir = std.Io.Dir.cwd().openDir(init.io, dir, .{ .iterate = true }) catch |err| {
        printError(init, "opening {s} - {}", .{ dir, err });
        return error.FileError;
    };

    defer open_dir.close(init.io);
    var it = open_dir.iterate();
    while (try it.next(init.io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (entry.name.len > 0 and (entry.name[0] == '.' or entry.name[0] == '_')) continue;

                const sub = try std.Io.Dir.path.join(arena, &.{ dir, entry.name });
                try collectRvFiles(init, arena, sub, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".rv")) continue;

                try out.append(arena, try std.Io.Dir.path.join(arena, &.{ dir, entry.name }));
            },
            else => {},
        }
    }
}

/// revo fmt
///
/// rewrite files/dirs in place, or list them with `check`
fn formatPaths(
    init: std.process.Init,
    gpa: Allocator,
    arena: Allocator,
    paths: []const [:0]const u8,
    check: bool,
    diff: bool,
) !void {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(arena);

    if (paths.len == 0) {
        try collectRvFiles(init, arena, ".", &files);
    } else for (paths) |p| {
        if (std.mem.eql(u8, p, "-")) {
            try files.append(arena, p);
        } else if (isDir(init, p)) {
            try collectRvFiles(init, arena, p, &files);
        } else {
            try files.append(arena, p);
        }
    }
    std.mem.sort([]const u8, files.items, {}, lessStr);

    var failed = false;
    var changed = false;

    var diff_buf = std.Io.Writer.Allocating.init(gpa);
    defer diff_buf.deinit();

    for (files.items) |path| {
        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();
        const file_alloc = file_arena.allocator();
        const is_stdin = std.mem.eql(u8, path, "-");

        const source: []const u8 = if (is_stdin) blk: {
            const piped = readStdin(init, file_alloc) catch {
                failed = true;
                continue;
            };
            break :blk piped orelse continue;
        } else std.Io.Dir.cwd().readFileAlloc(init.io, path, file_alloc, std.Io.Limit.unlimited) catch |err| {
            printError(init, "reading {s} - {}", .{ path, err });
            failed = true;
            continue;
        };

        // refuse to touch anything we cant parse; show the real diagnostic
        switch (try revo.lang.parse(file_alloc, .{ .name = path, .text = source }, .{})) {
            .ok => {},
            .err => |failure| {
                revo.printBuildError(gpa, .{ .name = path, .text = source }, .{ .parse = failure }, hostColor(init));
                failed = true;
                continue;
            },
        }

        const formatted = revo.lang.fmt.format(file_alloc, source) catch |err| {
            printError(init, "formatting {s} - {}", .{ path, err });
            failed = true;
            continue;
        };

        if (is_stdin) {
            if (check or diff) {
                if (!std.mem.eql(u8, formatted, source)) {
                    changed = true;
                    if (diff) {
                        diff_buf.clearRetainingCapacity();
                        try revo.diff.write(&diff_buf.writer, "-", source, formatted);
                        try printData(init, "{s}", .{diff_buf.written()});
                    } else try printData(init, "-\n", .{});
                }
                continue;
            }

            var out_buf: [4096]u8 = undefined;
            var out = revo.stdout().writer(init.io, &out_buf);
            try out.interface.writeAll(formatted);
            try out.flush();
            continue;
        }

        if (std.mem.eql(u8, formatted, source)) continue;
        changed = true;
        if (diff) {
            diff_buf.clearRetainingCapacity();
            try revo.diff.write(&diff_buf.writer, path, source, formatted);
            try printData(init, "{s}", .{diff_buf.written()});
            continue;
        }
        if (check) {
            try printData(init, "{s}\n", .{path});
            continue;
        }
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = formatted }) catch |err| {
            printError(init, "writing {s} - {}", .{ path, err });
            failed = true;
            continue;
        };
        try printData(init, "{s}\n", .{path});
    }

    if (failed) return error.CompilationError;
    if (check and changed) return error.FormatNeeded;
}

pub fn printRuntimeFailure(init: std.process.Init, failure: revo.RunFailure, source: []const u8) void {
    revo.printRunError(init.gpa, source, failure, hostColor(init));
}
