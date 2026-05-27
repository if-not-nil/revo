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
                // should never happen for `-`, but keep parity
                try runBytecode(init, init.gpa, "<stdin>", source, config);
            } else {
                switch (config.mode) {
                    .run => try runSource(init, init.gpa, "<stdin>", source, config),
                    .bench => try benchSource(init, init.gpa, "<stdin>", source, config),
                    .compile => try compileToBytecode(init, init.gpa, init.arena.allocator(), "<stdin>", source, config),
                    .docs => try printDocs(init, init.gpa, "<stdin>", source),
                    .disassemble => {
                        var vm = try initVM(init, init.gpa, config.argv);
                        defer vm.deinit();
                        const artifact = try compileSource(init, &vm, init.gpa, "<stdin>", source, config.test_mode);
                        defer init.gpa.free(artifact.instructions);
                        defer init.gpa.free(artifact.spans);
                        printDisassembly(artifact, source, false);
                    },
                }
            }
            if (!config.interactive) return;
        }
    } else {
        const stdout = std.Io.File.stdin();
        // no script path provided; if stdin is pipe, read it and run
        if (try stdout.isTty(init.io)) {
            const source = std.Io.Dir.cwd().readFileAlloc(init.io, "/dev/stdin", arena, std.Io.Limit.unlimited) catch |err| {
                printError(init, "reading stdin - {}", .{err});
                return error.FileError;
            };
            // run as src
            switch (config.mode) {
                .run => try runSource(init, init.gpa, "<stdin>", source, config),
                .bench => try benchSource(init, init.gpa, "<stdin>", source, config),
                .compile => try compileToBytecode(init, init.gpa, init.arena.allocator(), "<stdin>", source, config),
                .docs => try printDocs(init, init.gpa, "<stdin>", source),
                .disassemble => {
                    var vm = try initVM(init, init.gpa, config.argv);
                    defer vm.deinit();
                    const artifact = try compileSource(init, &vm, init.gpa, "<stdin>", source, config.test_mode);
                    defer init.gpa.free(artifact.instructions);
                    defer init.gpa.free(artifact.spans);
                    printDisassembly(artifact, source, false);
                },
            }
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
                    printDisassembly(.{
                        .instructions = deserialized.instructions,
                        .spans = deserialized.spans,
                    }, "", false);
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
            switch (config.mode) {
                .run => try runSource(init, init.gpa, path, source, config),
                .bench => try benchSource(init, init.gpa, path, source, config),
                .compile => try compileToBytecode(init, init.gpa, arena, path, source, config),
                .docs => try printDocs(init, init.gpa, path, source),
                .disassemble => {
                    var vm = try initVM(init, init.gpa, config.argv);
                    defer vm.deinit();

                    const artifact = try compileSource(init, &vm, init.gpa, path, source, config.test_mode);
                    defer init.gpa.free(artifact.instructions);
                    defer init.gpa.free(artifact.spans);
                    printDisassembly(artifact, source, false);
                },
            }
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

fn handleBuildError(init: std.process.Init, gpa: Allocator, source_name: []const u8, source_text: []const u8, err: anytype) void {
    var buf = std.Io.Writer.Allocating.init(gpa);
    defer buf.deinit();
    revo.lang.renderError(gpa, &buf.writer, .{ .name = source_name, .text = source_text }, err) catch |render_err| {
        printError(init, "while rendering error - {}", .{render_err});
    };
    std.debug.print("{s}", .{buf.written()});
    revo.lang.deinitError(gpa, err);
}

fn compileSource(init: std.process.Init, vm: *VM, gpa: Allocator, source_name: []const u8, source_text: []const u8, test_mode: bool) !Artifact {
    const build_result = revo.lang.build(vm, .{ .name = source_name, .text = source_text }, .{ .test_mode = test_mode }) catch |err| {
        printError(init, "compilation - {}", .{err});
        return error.CompilationError;
    };

    return switch (build_result) {
        .ok => |art| art,
        .err => |lang_err| {
            handleBuildError(init, gpa, source_name, source_text, lang_err);
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
    init: std.process.Init,
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
            var buf = std.Io.Writer.Allocating.init(gpa);
            defer buf.deinit();
            failure.render(gpa, &buf.writer, source) catch |err| {
                printError(init, "while rendering runtime error - {}", .{err});
                return;
            };
            std.debug.print("{s}", .{buf.written()});
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
        }
    }

    const run_result = try revo.module.runCompiledModuleReport(vm, name, artifact.instructions);
    switch (run_result) {
        .ok => if (echo_last) try printResult(vm),
        .err => |failure| printRuntimeFailure(init, failure, source),
    }

    printBenchStats(vm, times.items);
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

pub fn printRuntimeFailure(init: std.process.Init, failure: anytype, source: []const u8) void {
    var buf = std.Io.Writer.Allocating.init(init.gpa);
    defer buf.deinit();
    failure.render(init.gpa, &buf.writer, source) catch |render_err| {
        printError(init, "while rendering runtime error - {}", .{render_err});
        return;
    };
    std.debug.print("{s}", .{buf.written()});
}

fn printBenchStats(_: *VM, times: []std.Io.Duration) void {
    std.mem.sort(std.Io.Duration, times, {}, struct {
        pub fn lessThan(_: void, a: std.Io.Duration, b: std.Io.Duration) bool {
            return a.nanoseconds < b.nanoseconds;
        }
    }.lessThan);

    const best = if (times.len > 0) times[0].nanoseconds else @as(i96, 0);
    const worst = if (times.len > 0) times[times.len - 1].nanoseconds else @as(i96, 0);
    const median = if (times.len > 0) times[times.len / 2].nanoseconds else @as(i96, 0);
    const p95_idx = if (times.len > 0) @min(times.len - 1, (times.len * 95) / 100) else 0;
    const p95 = if (times.len > 0) times[p95_idx].nanoseconds else @as(i96, 0);

    const best_ms = @as(f64, @floatFromInt(best)) / 1_000_000.0;
    const worst_ms = @as(f64, @floatFromInt(worst)) / 1_000_000.0;
    const median_ms = @as(f64, @floatFromInt(median)) / 1_000_000.0;
    const p95_ms = @as(f64, @floatFromInt(p95)) / 1_000_000.0;

    std.debug.print("+=========================\n", .{});
    std.debug.print("| best    {d:.3}ms / {d}ns\n", .{ best_ms, best });
    std.debug.print("| median  {d:.3}ms / {d}ns\n", .{ median_ms, median });
    std.debug.print("| p95     {d:.3}ms / {d}ns\n", .{ p95_ms, p95 });
    std.debug.print("| worst   {d:.3}ms / {d}ns\n", .{ worst_ms, worst });
}

fn printDisassembly(artifact: Artifact, source: []const u8, json: bool) void {
    if (!json) {
        std.debug.print(
            \\ pc  op                a  b  c    bx    src
            \\ --  ----------------  -  -  ---  ---  ---------
            \\
        , .{});
    }

    for (artifact.instructions, 0..) |instr, pc| {
        const span = if (pc < artifact.spans.len)
            artifact.spans[pc]
        else
            revo.lang.Span{ .start = 0, .end = 0, .line = 0, .column = 0 };

        if (json) continue;

        const op_name = @tagName(instr.op);

        if (false and std.mem.eql(u8, op_name, "jump") or
            std.mem.eql(u8, op_name, "closure") or
            std.mem.eql(u8, op_name, "call") or
            std.mem.eql(u8, op_name, "halt") or
            std.mem.eql(u8, op_name, "ret") or
            std.mem.eql(u8, op_name, "load_const") or
            span.start >= source.len or
            (span.end - span.start) > 200)
        {
            continue;
        }

        var span_buf: [80]u8 = undefined;
        const span_text = blk: {
            if (source.len == 0 or span.start >= source.len) break :blk "";
            const end = @min(span.end, source.len);
            if (end <= span.start) break :blk "";
            const raw = source[span.start..end];
            var out_idx: usize = 0;
            var in_ws = false;
            for (raw) |ch| {
                const is_ws = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
                if (out_idx >= span_buf.len - 1) break;
                if (is_ws) {
                    if (!in_ws) {
                        span_buf[out_idx] = ' ';
                        out_idx += 1;
                        in_ws = true;
                    }
                } else {
                    span_buf[out_idx] = ch;
                    out_idx += 1;
                    in_ws = false;
                }
            }
            if (out_idx > 30) break :blk span_buf[0..30];
            break :blk span_buf[0..out_idx];
        };

        std.debug.print("{d: >2}  {s: <16}  {d}  {d}  {d: >3}  {d: >3}  {s}\n", .{
            pc, op_name, instr.a, instr.b, instr.c, instr.bx, span_text,
        });

        const raw_line = blk: {
            var s = span.start;
            while (s > 0 and source[s - 1] != '\n') : (s -= 1) {}
            var e = if (span.end <= source.len) span.end else source.len;
            while (e < source.len and source[e] != '\n') : (e += 1) {}
            break :blk source[s..e];
        };

        if (raw_line.len > 0) {
            var line_buf: [1024]u8 = undefined;
            const line_display = line_buf[0..@min(raw_line.len, line_buf.len)];
            @memcpy(line_display, raw_line[0..line_display.len]);
            for (line_display) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
                c.* = ' ';
            };

            const offset_in_line = span.start - blk: {
                var s = span.start;
                while (s > 0 and source[s - 1] != '\n') : (s -= 1) {}
                break :blk s;
            };
            const highlight_len = @max(1, @min(30, span.end -| span.start));

            std.debug.print("         | {s}\n", .{line_display});
            std.debug.print("         | ", .{});
            for (0..offset_in_line) |_| std.debug.print(" ", .{});
            for (0..highlight_len) |_| std.debug.print("^", .{});
            std.debug.print(" [{d}:{d}]\n", .{ span.line, span.column });
        }
    }
}
