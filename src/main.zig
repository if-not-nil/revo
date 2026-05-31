const std = @import("std");
const Allocator = std.mem.Allocator;

const revo = @import("revo");
const Artifact = revo.lang.Artifact;
const VM = revo.VM;
const pretty = revo.pretty;

const repl = @import("repl.zig");

test {
    _ = std.testing.refAllDecls(repl);
}

const USAGE =
    \\usage: revo [options] [script [args...]]
    \\
    \\options:
    \\  -e code          run code
    \\  -i               enter interactive mode after executing
    \\  -d               output the last value the program evaluated
    \\  -b               compile script to bytecode (.rvo)
    \\  -o path          output path for -b (default: input with .rvo extension)
    \\  --test           run test blocks
    \\  --bench[n]       run with performance counters ([n] iterations, 1 if not specified)
    \\  --dis            show bytecode disassembly instead of running
    \\  --docs           statically extract @doc function docs from source
    \\  -h, --help       show this help message
    \\  --version        show version
    \\
    \\examples:
    \\  revo                           start interactive REPL
    \\  revo script.rv                 run script
    \\  revo -e "1 + 2"                run inline code
    \\  revo -e "1 + 2" -i             run inline code and enter REPL
    \\  revo -b script.rv              compile script to bytecode
    \\  revo -b -o output.rvo script   compile script with custom output path
    \\  revo --bench script.rv         run with performance counters
    \\  revo --dis script.rv           show bytecode disassembly
    \\  revo --docs script.rv          print extracted docs without running code
;

const ExecutionMode = enum { run, bench, disassemble, compile, docs };

const Config = struct {
    mode: ExecutionMode = .run,
    inline_code: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    interactive: bool = false,
    test_mode: bool = false,
    bench_iters: u32 = 1,
    echo_last: bool = false,
    argv: []const [:0]const u8 = &.{},
};

pub fn main(init: std.process.Init) void {
    pretty.supports_color = pretty.isColorSupported(init.environ_map, init.io);

    runMain(init) catch |x| switch (x) {
        error.VmInitError,
        error.InsufficientArgs,
        error.InvalidArgs,
        error.UnknownCommand,
        error.CompilationError,
        error.FileError,
        error.HelpRequested,
        error.VersionRequested,
        => {},
        else => |err| {
            var stderr_buf: [256]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);
            pretty.printErrorName(init.gpa, &stderr.interface, err) catch return;
        },
    };
}

fn handleSource(init: std.process.Init, gpa: Allocator, arena: Allocator, name: []const u8, source: []const u8, config: Config) !void {
    switch (config.mode) {
        .run => try runSource(init, gpa, name, source, config),
        .bench => try benchSource(init, gpa, name, source, config),
        .compile => try compileToBytecode(init, gpa, arena, name, source, config),
        .docs => try printDocs(init, gpa, name, source),
        .disassemble => {
            var vm = try initVM(init, gpa, config.argv);
            defer vm.deinit();
            const artifact = try compileSource(init, &vm, gpa, name, source, config.test_mode);
            defer gpa.free(artifact.instructions);
            defer gpa.free(artifact.spans);
            revo.vm.debug.printDisassembly(artifact, source);
        },
    }
}

fn runMain(init: std.process.Init) !void {
    var arena_instance = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        const stdin_file = std.Io.File.stdin();
        if (!try stdin_file.isTty(init.io)) {
            const source = std.Io.Dir.cwd().readFileAlloc(init.io, "/dev/stdin", arena, std.Io.Limit.unlimited) catch |err| {
                printError(init, "reading stdin - {}", .{err});
                return error.FileError;
            };

            const cfg: Config = .{};
            var vm = try initVM(init, init.gpa, &.{args[0]});
            defer vm.deinit();
            try runSource(init, init.gpa, "<stdin>", source, cfg);
            return;
        }

        var vm = try initVM(init, init.gpa, &.{args[0]});
        defer vm.deinit();
        try repl.run(&vm, init.gpa, init);
        return;
    }

    const config = try parseArgs(init, args);

    // if script path `-` then explicit stdin;
    // else if no script path and stdin is pipe, read stdin then run
    if (config.script_path) |path| {
        if (std.mem.eql(u8, path, "-")) {
            const source = std.Io.Dir.cwd().readFileAlloc(init.io, "/dev/stdin", arena, std.Io.Limit.unlimited) catch |err| {
                printError(init, "reading stdin - {}", .{err});
                return error.FileError;
            };
            if (std.mem.endsWith(u8, path, ".rvo")) {
                try runBytecode(init, init.gpa, "<stdin>", source, config);
            } else {
                try handleSource(init, init.gpa, init.arena.allocator(), "<stdin>", source, config);
            }
            if (!config.interactive) return;
        }
    } else {
        const stdin_file = std.Io.File.stdin();
        if (!try stdin_file.isTty(init.io)) {
            const source = std.Io.Dir.cwd().readFileAlloc(init.io, "/dev/stdin", arena, std.Io.Limit.unlimited) catch |err| {
                printError(init, "reading stdin - {}", .{err});
                return error.FileError;
            };
            try handleSource(init, init.gpa, init.arena.allocator(), "<stdin>", source, config);
            if (!config.interactive) return;
        }
    }

    if (config.inline_code) |code| {
        try runInlineCode(init, init.gpa, code, config);
        if (!config.interactive and config.script_path == null) return;
    }

    if (config.script_path) |path| {
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
                    revo.vm.debug.printDisassembly(.{
                        .instructions = deserialized.instructions,
                        .spans = deserialized.spans,
                    }, "");
                },
                .compile => {
                    printError(init, "cannot compile bytecode files", .{});
                    return error.InvalidArgs;
                },
                .docs => {
                    printError(init, "cannot extract docs from bytecode files", .{});
                    return error.InvalidArgs;
                },
            }
        } else {
            try handleSource(init, init.gpa, arena, path, source, config);
        }
        if (!config.interactive) return;
    }

    var vm = try initVM(init, init.gpa, config.argv);
    defer vm.deinit();
    try repl.run(&vm, init.gpa, init);
}

fn printError(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    pretty.printError(init.gpa, &buf.writer, fmt, args) catch return;
    std.debug.print("{s}", .{buf.written()});
}

fn printSuccess(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    pretty.printSuccess(init.gpa, &buf.writer, fmt, args) catch return;
    std.debug.print("{s}", .{buf.written()});
}

fn initVM(init: std.process.Init, gpa: Allocator, argv: []const [:0]const u8) !VM {
    return VM.init(.{ .alloc = gpa, .io = init.io, .argv = argv }) catch |err| {
        printError(init, "initializing vm - {}", .{err});
        return error.VmInitError;
    };
}

fn handleBuildError(_: std.process.Init, gpa: Allocator, source_name: []const u8, source_text: []const u8, err: anytype) void {
    revo.printBuildError(gpa, .{ .name = source_name, .text = source_text }, err);
}

fn compileSource(init: std.process.Init, vm: *VM, gpa: Allocator, source_name: []const u8, source_text: []const u8, test_mode: bool) !Artifact {
    var ws = try revo.lang.Workspace.init(vm, gpa);
    defer ws.deinit();

    const build_result = ws.analyzeSource(gpa, source_name, source_text, .{ .test_mode = test_mode }) catch |err| {
        printError(init, "compilation - {}", .{err});
        return error.CompilationError;
    };

    return switch (build_result) {
        .ok => |art| art,
        .err => |lang_err| {
            handleBuildError(init, gpa, source_name, source_text, lang_err);
            vm.runtime.resetDiagArena();
            return error.CompilationError;
        },
    };
}

fn printResult(vm: *VM) !void {
    var res = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer res.deinit();
    vm.mainResult().write(&res.writer, vm, .debug) catch return;
    std.debug.print("{s}", .{res.written()});
}

fn runCompiledArtifact(
    _: std.process.Init,
    gpa: Allocator,
    vm: *VM,
    name: []const u8,
    artifact: Artifact,
    source: []const u8,
    echo_last: bool,
) !void {
    try vm.setProgramDebugInfo(artifact.spans, source, name);

    const run_result = try revo.module.runCompiledModuleReport(vm, name, artifact.instructions);
    switch (run_result) {
        .ok => if (echo_last) try printResult(vm),
        .err => |failure| {
            revo.printEvalError(gpa, source, failure);
            vm.runtime.resetDiagArena();
        },
    }
}

fn parseArgs(init: std.process.Init, args: []const [:0]const u8) !Config {
    var config: Config = .{};
    var i: usize = 1;

    var argv: std.ArrayList([:0]const u8) = .empty;

    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= args.len) {
                printError(init, "-e requires an argument", .{});
                return error.InsufficientArgs;
            }
            try argv.append(init.arena.allocator(), args[0]);
            config.inline_code = args[i];
            config.echo_last = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            config.interactive = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            config.echo_last = true;
        } else if (std.mem.eql(u8, arg, "-b")) {
            config.mode = .compile;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                printError(init, "-o requires an argument", .{});
                return error.InsufficientArgs;
            }
            config.output_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--bench")) {
            config.mode = .bench;
            if (arg.len > 7) {
                const iters = arg[7..];
                config.bench_iters = std.fmt.parseUnsigned(u32, iters, 10) catch |err| {
                    printError(init, "invalid --bench[n] value '{s}' - {}", .{ iters, err });
                    return error.InvalidArgs;
                };
            }
        } else if (std.mem.eql(u8, arg, "--test")) {
            config.test_mode = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            config.test_mode = true;
        } else if (std.mem.eql(u8, arg, "--dis")) {
            config.mode = .disassemble;
        } else if (std.mem.eql(u8, arg, "--docs")) {
            config.mode = .docs;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}\n", .{USAGE});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("revo " ++ @import("build_options").version ++ "\n", .{});
            return error.VersionRequested;
        } else if (std.mem.eql(u8, arg, "-")) {
            config.script_path = arg;
            try argv.append(init.arena.allocator(), arg);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            printError(init, "unknown option '{s}'", .{arg});
            std.debug.print("{s}\n", .{USAGE});
            return error.UnknownCommand;
        } else if (config.inline_code == null) {
            if (config.script_path == null)
                config.script_path = arg;
            try argv.append(init.arena.allocator(), arg);
        } else {
            try argv.append(init.arena.allocator(), arg);
        }
        i += 1;
    }
    config.argv = try argv.toOwnedSlice(init.arena.allocator());

    return config;
}

fn printDocs(init: std.process.Init, gpa: Allocator, source_name: []const u8, source: []const u8) !void {
    const res = revo.lang.docs.extractDocs(gpa, source) catch |err| switch (err) {
        error.ParseFailed => {
            printError(init, "parse error while extracting docs", .{});
            return error.CompilationError;
        },
        else => |e| return e,
    };
    defer {
        for (res.items) |it| gpa.free(it.name);
        gpa.free(res.items);
        res.arena.deinit();
    }

    std.debug.print("# docs for {s}\n", .{source_name});
    if (res.items.len == 0) {
        std.debug.print("(no @doc function docs found)\n", .{});
        return;
    }

    for (res.items) |it| {
        std.debug.print("\n- {s}/{d}\n{s}\n", .{ it.name, it.arity, it.doc });
    }
}

fn runInlineCode(init: std.process.Init, gpa: Allocator, code: []const u8, config: Config) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, "<inline>", code, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    try runCompiledArtifact(init, gpa, &vm, "<inline>", artifact, code, config.echo_last);
}

fn runSource(init: std.process.Init, gpa: Allocator, path: []const u8, source: []const u8, config: Config) !void { // echo_last: bool, test_mode: bool) !void {
    var vm = try initVM(init, gpa, config.argv);
    defer vm.deinit();

    const artifact = try compileSource(init, &vm, gpa, path, source, config.test_mode);
    defer gpa.free(artifact.instructions);
    defer gpa.free(artifact.spans);

    try vm.setProgramDebugInfo(artifact.spans, source, path);

    // std.debug.print("running\n", .{});
    try runCompiledArtifact(init, gpa, &vm, path, artifact, source, config.echo_last);
}

fn runBytecode(init: std.process.Init, gpa: Allocator, path: []const u8, bytecode_data: []const u8, config: Config) !void {
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
    echo_last: bool,
) !void {
    var times = try std.ArrayList(std.Io.Duration).initCapacity(gpa, iters);
    defer times.deinit(gpa);

    for (0..iters) |_| {
        const t_start = std.Io.Timestamp.now(init.io, .cpu_process);
        const run_result = try revo.module.runCompiledModuleReport(vm, name, artifact.instructions);
        const t_end = std.Io.Timestamp.now(init.io, .cpu_process);
        times.appendAssumeCapacity(t_start.durationTo(t_end));

        if (run_result == .err) {
            const failure = run_result.err;
            printRuntimeFailure(init, failure, source);
            vm.runtime.resetDiagArena();
        }
    }

    const run_result = try revo.module.runCompiledModuleReport(vm, name, artifact.instructions);
    switch (run_result) {
        .ok => if (echo_last) try printResult(vm),
        .err => |failure| {
            printRuntimeFailure(init, failure, source);
            vm.runtime.resetDiagArena();
        },
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

    try benchArtifact(init, gpa, &vm, path, artifact, source, config.bench_iters, config.echo_last);
}

fn benchBytecode(init: std.process.Init, gpa: Allocator, path: []const u8, bytecode_data: []const u8, config: Config) !void {
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

fn compileToBytecode(init: std.process.Init, gpa: Allocator, arena: Allocator, path: []const u8, source: []const u8, config: Config) !void {
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
