const std = @import("std");
const Allocator = std.mem.Allocator;
const build_opts = @import("build_options");
const lsp_enabled = build_opts.lsp_enabled;

const revo = @import("revo");
const docs = revo.lang.docs;
const Artifact = revo.lang.Artifact;
const VM = revo.VM;
const pretty = revo.pretty;

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
    \\  revo bench script.rv              run with performance counters
    \\  revo dis script.rv                show bytecode disassembly
    \\  revo doc script.rv                print extracted docs as markdown
    \\  revo doc --html src/std/iface     render the stdlib reference as html
    \\  revo doc --html src/std/iface < std.md > std.new   splice into a doc page
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
    return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ SYNOPSIS, auto, EXAMPLES });
}

const ExecutionMode = enum { run, repl, bench, disassemble, compile, docs, docs_html, lsp };

const Config = struct {
    mode: ExecutionMode = .run,
    inline_code: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    interactive: bool = false,
    test_mode: bool = false,
    bench_iters: u32 = 1,
    echo_last: ?revo.Data.RenderMode = null,
    force_splice: bool = false,
    argv: []const [:0]const u8 = &.{},
};

pub fn main(provided_init: std.process.Init) void {
    var init = provided_init;
    pretty.supports_color = pretty.isColorSupported(init.environ_map, init.io);

    if (build_opts.mimalloc) init.gpa = @import("mimalloc").mim_allocator;

    runMain(init) catch |x| switch (x) {
        error.VmInitError,
        error.InsufficientArgs,
        error.InvalidArgs,
        error.UnknownCommand,
        error.CompilationError,
        error.FileError,
        => std.process.exit(1),
        error.HelpRequested,
        error.VersionRequested,
        => {},
        else => |err| {
            var stderr_buf: [256]u8 = undefined;
            var stderr = revo.stderr().writer(init.io, &stderr_buf);
            pretty.printError(&stderr.interface, "{s}", .{@errorName(err)}) catch return;
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
        .docs, .docs_html => unreachable,
        .disassemble => {
            var vm = try initVM(init, gpa, config.argv);
            defer vm.deinit();
            const artifact = try compileSource(init, &vm, gpa, name, source, config.test_mode);
            defer gpa.free(artifact.instructions);
            defer gpa.free(artifact.spans);
            try revo.vm.debug.printDisassembly(&vm, artifact, source);
        },
        .repl, .lsp => unreachable,
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
            var vm = try initVM(init, init.gpa, &.{args[0]});
            defer vm.deinit();
            try revo.std_lib.populateArgv(&vm);
            try runSource(init, init.gpa, "<stdin>", s, .{});
            return;
        }
        var vm = try initVM(init, init.gpa, &.{args[0]});
        defer vm.deinit();
        try revo.std_lib.populateArgv(&vm);
        try repl.run(&vm, init.gpa, init);
        return;
    }

    const config = try parseArgs(init, args);

    // early-return modes
    if (config.mode == .repl) {
        var vm = try initVM(init, init.gpa, config.argv);
        defer vm.deinit();
        try revo.std_lib.populateArgv(&vm);
        return try repl.run(&vm, init.gpa, init);
    }
    if (config.mode == .lsp) {
        var project = revo.lang.Project.detectFromCwd(init.io, init.gpa);
        defer project.deinit(init.gpa);
        return try @import("lsp_main").runLsp(init.gpa, init.io, project.mode, project.root);
    }
    if (config.mode == .docs or config.mode == .docs_html) {
        return try docs.Cli.run(init, init.gpa, arena, config.script_path, config.mode == .docs_html, config.force_splice);
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
                    .run => try runBytecode(init, init.gpa, path, source, config),
                    .bench => try benchBytecode(init, init.gpa, path, source, config),
                    .disassemble => {
                        var vm = try initVM(init, init.gpa, config.argv);
                        defer vm.deinit();
                        var deserialized = revo.bytecode.deserialize(&vm, source, init.gpa) catch |err| {
                            printError(init, "deserializing bytecode - {}", .{err});
                            return error.CompilationError;
                        };
                        defer deserialized.deinit();
                        try revo.vm.debug.printDisassembly(&vm, .{
                            .instructions = deserialized.instructions,
                            .spans = deserialized.spans,
                        }, "");
                    },
                    .compile => {
                        printError(init, "cannot compile bytecode files", .{});
                        return error.InvalidArgs;
                    },
                    .docs, .docs_html => {
                        printError(init, "cannot extract docs from bytecode files", .{});
                        return error.InvalidArgs;
                    },
                    .repl, .lsp => unreachable,
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

    var vm = try initVM(init, init.gpa, config.argv);
    defer vm.deinit();
    try revo.std_lib.populateArgv(&vm);
    try repl.run(&vm, init.gpa, init);
}

fn printError(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    pretty.printError(&buf.writer, fmt, args) catch return;
    std.debug.print("{s}", .{buf.written()});
}

fn printSuccess(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    pretty.printSuccess(&buf.writer, fmt, args) catch return;
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
        try runBytecode(init, gpa, "<stdin>", source, config);
    } else {
        try handleSource(init, gpa, arena, "<stdin>", source, config);
    }
}

fn initVM(init: std.process.Init, gpa: Allocator, argv: []const [:0]const u8) !VM {
    return VM.init(.{ .alloc = gpa, .io = init.io, .argv = argv, .diag_alloc = gpa }) catch |err| {
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
) !Artifact {
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
        revo.printBuildError(gpa, .{ .name = source_name, .text = source_text }, lang_err);
        analysis.diagnostics = null;
        vm.runtime.resetDiagArena();
        return error.CompilationError;
    }

    const artifact = analysis.artifact.?;
    analysis.artifact = null;
    return artifact;
}

fn printResult(vm: *VM, mode: revo.Data.RenderMode) !void {
    var res = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer res.deinit();
    vm.mainResult().write(&res.writer, vm, mode) catch return;
    std.debug.print("{s}\n", .{res.written()});
}

fn runCompiledArtifact(
    _: std.process.Init,
    gpa: Allocator,
    vm: *VM,
    name: []const u8,
    artifact: Artifact,
    source: []const u8,
    echo_last: ?revo.Data.RenderMode,
) !void {
    try vm.setProgramDebugInfo(artifact.spans, source, name);

    const run_result = try revo.module.runCompiledModuleReport(vm, name, artifact.instructions);
    switch (run_result) {
        .ok => if (echo_last) |mode| try printResult(vm, mode),
        .err => |failure| {
            revo.printEvalError(gpa, source, failure);
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
        .{ .name = "i", .short = 'i', .kind = .boolean, .description = "enter repl after executing" },
        .{ .name = "d", .short = 'd', .kind = .boolean, .description = "output the program's result in display mode" },
        .{ .name = "D", .short = 'D', .kind = .boolean, .description = "output the program's result in debug mode" },
        .{ .name = "P", .short = 'P', .kind = .boolean, .description = "output the program's result in pretty mode" },
        .{ .name = "test", .kind = .boolean, .description = "run with test blocks" },
        .{ .name = "html", .kind = .boolean, .description = "render as html instead of markdown (doc)" },
        .{ .name = "splice", .kind = .boolean, .description = "splice output into markdown piped on stdin (doc)" },
        .{ .name = "help", .short = 'h', .kind = .boolean, .description = "show this help message" },
        // terminal positional:
        //   stops flag-parsing, goes to passthru argv
        //   output path (compile mode) is handled below by hand
        .{ .name = "script", .kind = .positional, .terminal = true, .passthrough = true },
    };

    var commands_buf: [7]ap.Command = undefined;
    var n: usize = 0;
    inline for (&[_]struct { name: []const u8, prefix: bool, has_validate: bool, desc: []const u8 }{
        .{ .name = "compile", .prefix = false, .has_validate = false, .desc = "compile script to bytecode instead of running" },
        .{ .name = "repl", .prefix = false, .has_validate = false, .desc = "start repl (default with no args)" },
        .{ .name = "lsp", .prefix = false, .has_validate = false, .desc = "start the lsp" },
        .{ .name = "dis", .prefix = false, .has_validate = false, .desc = "show bytecode disassembly instead of running" },
        .{ .name = "doc", .prefix = false, .has_validate = false, .desc = "extract doc comments from a file, dir, or the pwd workspace" },
        .{ .name = "version", .prefix = false, .has_validate = false, .desc = "show version and build info" },
        .{ .name = "bench", .prefix = true, .has_validate = true, .desc = "run with performance counters ([n] iterations, 1 if not specified)" },
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
        if (arg_list[8].enabled) { // help always wins
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

    if (arg_list[8].enabled) { // help
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
            if (std.mem.eql(u8, cmd.name, "doc")) config.mode = .docs;
            if (std.mem.eql(u8, cmd.name, "bench")) {
                config.mode = .bench;
                config.bench_iters = if (cmd.value.len == 0) 1 else std.fmt.parseUnsigned(u32, cmd.value, 10) catch 1;
            }
        }
    }

    // map flags
    config.interactive = arg_list[1].enabled; // -i
    config.test_mode = arg_list[5].enabled; // --test
    config.force_splice = arg_list[7].enabled; // --splice
    if (arg_list[2].enabled) config.echo_last = .display; // -d
    if (arg_list[3].enabled) config.echo_last = .debug; // -D
    if (arg_list[4].enabled) config.echo_last = .pretty; // -P
    if (arg_list[6].enabled and config.mode == .docs) config.mode = .docs_html; // --html

    // -e always gets the script slot
    if (arg_list[0].value) |code| { // -e
        config.inline_code = code;
        try leftover.insert(allocator, 0, args[0]);
    } else {
        config.script_path = arg_list[9].value; // script positional
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
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, "<inline>", code, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    try revo.std_lib.populateArgv(&vm);
    try runCompiledArtifact(init, gpa, &vm, "<inline>", artifact, code, config.echo_last);
}

fn runSource(
    init: std.process.Init,
    gpa: Allocator,
    path: []const u8,
    source: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    try vm.setProgramDebugInfo(artifact.spans, source, path);

    try revo.std_lib.populateArgv(&vm);
    try runCompiledArtifact(init, gpa, &vm, path, artifact, source, config.echo_last);
}

fn runBytecode(
    init: std.process.Init,
    gpa: Allocator,
    path: []const u8,
    bytecode_data: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    var deserialized = revo.bytecode.deserialize(&vm, bytecode_data, gpa) catch |err| {
        printError(init, "deserializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer deserialized.deinit();

    vm.setProgramDebugInfo(deserialized.spans, "", path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    try revo.std_lib.populateArgv(&vm);
    try runCompiledArtifact(
        init,
        gpa,
        &vm,
        path,
        .{ .spans = deserialized.spans, .instructions = deserialized.instructions },
        "",
        config.echo_last,
    );
}

fn benchArtifact(
    init: std.process.Init,
    gpa: Allocator,
    vm: *VM,
    name: []const u8,
    artifact: Artifact,
    source: []const u8,
    iters: u32,
    echo_last: ?revo.Data.RenderMode,
) !void {
    var times = try std.ArrayList(std.Io.Duration).initCapacity(gpa, iters);
    defer times.deinit(gpa);

    var last_result: ?revo.EvalResult = null;

    for (0..iters) |_| {
        const t_start = std.Io.Timestamp.now(init.io, .cpu_process);
        const run_result = try revo.module.runCompiledModuleReport(vm, name, artifact.instructions);
        const t_end = std.Io.Timestamp.now(init.io, .cpu_process);
        times.appendAssumeCapacity(t_start.durationTo(t_end));
        last_result = run_result;

        if (run_result == .err) {
            printRuntimeFailure(init, run_result.err, source);
            vm.runtime.resetDiagArena();
        }
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

    revo.vm.debug.printBenchStats(times.items);
}

fn benchSource(init: std.process.Init, gpa: Allocator, path: []const u8, source: []const u8, config: Config) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    vm.setProgramDebugInfo(artifact.spans, source, path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    try revo.std_lib.populateArgv(&vm);
    try benchArtifact(init, gpa, &vm, path, artifact, source, config.bench_iters, config.echo_last);
}

fn benchBytecode(
    init: std.process.Init,
    gpa: Allocator,
    path: []const u8,
    bytecode_data: []const u8,
    config: Config,
) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    var deserialized = revo.bytecode.deserialize(&vm, bytecode_data, gpa) catch |err| {
        printError(init, "deserializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer deserialized.deinit();

    vm.setProgramDebugInfo(deserialized.spans, "", path) catch |err| {
        std.debug.print("debug info error - {}\n", .{err});
    };

    try revo.std_lib.populateArgv(&vm);
    try benchArtifact(
        init,
        gpa,
        &vm,
        path,
        .{ .instructions = deserialized.instructions, .spans = deserialized.spans },
        "",
        config.bench_iters,
        config.echo_last,
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
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    const bytecode = revo.bytecode.serialize(&vm, artifact, gpa) catch |err| {
        printError(init, "serializing bytecode - {}", .{err});
        return error.CompilationError;
    };
    defer gpa.free(bytecode);

    const output_path: []const u8 = if (config.output_path) |provided|
        provided
    else blk: {
        if (std.mem.endsWith(u8, path, ".rv")) {
            const base = path[0 .. path.len - 3];
            break :blk std.fmt.allocPrint(arena, "{s}.rvo", .{base}) catch {
                printError(init, "output path allocation failed", .{});
                return error.FileError;
            };
        } else {
            break :blk std.fmt.allocPrint(arena, "{s}.rvo", .{path}) catch {
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

pub fn printRuntimeFailure(init: std.process.Init, failure: revo.EvalFailure, source: []const u8) void {
    revo.printEvalError(init.gpa, source, failure);
}
