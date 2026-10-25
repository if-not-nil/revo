const bindings = @import("src/capi/header_gen.zig");
const builtin = @import("builtin");
const std = @import("std");
const Translator = @import("translate_c").Translator;

const Build = std.Build;
const Module = Build.Module;
const logger = std.log.scoped(.@"build/revo");

const VERSION = "0.1.2";

const ReleaseTarget = struct {
    triple: []const u8,
    wasi_cli: bool = false,
};

const release_targets: []const ReleaseTarget = &.{
    .{ .triple = "aarch64-macos" }, // good
    // golden target for linux (static musl cant load .so's)
    .{ .triple = "x86_64-linux-gnu" }, // good
    .{ .triple = "aarch64-linux-gnu" }, // probably good
    // plus static musl ones for machines with no (or ancient) glibc
    .{ .triple = "x86_64-linux-musl" }, // good
    .{ .triple = "aarch64-linux-musl" }, // probably good
    .{ .triple = "x86_64-macos" }, // untested
    .{ .triple = "x86_64-windows" }, // missing dll loading, isocline and async
    // we want at least one freestanding target in the matrix
    //   at all times to confirm this can work on the rest of freestanding
    .{ .triple = "wasm32-freestanding" }, // good, see `wasm/`
    // .{ .triple = "wasm64-freestanding" }, // good, see `wasm/`. use wasm32 instead
    .{ .triple = "wasm32-wasi" }, // web build with js host imports
    .{ .triple = "wasm32-wasi", .wasi_cli = true }, // cli build with wasi syscalls (wasmtime/runnable)

    // entirely untested:
    .{ .triple = "x86_64-freebsd-none" }, // probably good
    .{ .triple = "x86_64-openbsd-none" }, // probably good
    // nobody runs netbsd anymore
};

const Features = packed struct {
    /// ~ requires libc, not available on windows/wasi/freestanding
    isocline: bool = false,
    /// ~  available everywhere except freestanding
    lsp: bool = false,
    /// ~  available everywhere
    regex: bool = false,
    /// ~  available everywhere except freestanding
    mimalloc: bool = false,
    /// ~ dynamic c calls need dlopen; posix only
    ffi: bool = false,
    zig_backend: bool = false,
    // ~ async: requires posix threads, not available on windows/wasi/freestanding
};

const release_target_queries = blk: {
    // zig master's target-query parse path can exceed the default comptime quota???
    @setEvalBranchQuota(200_000);
    // pre-computes queries
    var arr: [release_targets.len]std.Target.Query = undefined;
    var bad_targets: []const u8 = &.{};
    for (release_targets, &arr) |target_def, *out| {
        out.* = std.Target.Query.parse(.{ .arch_os_abi = target_def.triple }) catch {
            if (bad_targets.len >= 1) {
                bad_targets = bad_targets ++ ", ";
            }
            bad_targets = bad_targets ++ "\"" ++ target_def.triple ++ "\"";
        };
    }
    if (bad_targets.len >= 1) {
        @compileError("Invalid target(s): " ++ bad_targets);
    }

    const c_arr = arr;
    break :blk &c_arr;
};

fn getFeatures(features: []const u8) Features {
    var ret = Features{};
    if (features.len == 0) return ret;

    var it = std.mem.splitScalar(u8, features, ',');
    while (it.next()) |token| {
        if (std.mem.trim(u8, token, " \n\r\t").len == 0) continue;

        const info = @typeInfo(Features).@"struct";
        inline for (info.field_names) |field_name| {
            if (std.mem.eql(u8, token, field_name)) {
                if (@field(ret, field_name)) {
                    std.log.warn("Duplicate feature: {s}", .{token});
                }
                @field(ret, field_name) = true;
                break;
            }
        } else std.log.warn("Unknown feature: {s}", .{token});
    }
    return ret;
}

/// for release bin names
fn binName(b: *std.Build, triple: []const u8) []const u8 {
    return b.fmt("revo-{s}-{s}", .{ VERSION, triple });
}

const ExeFeatures = struct {
    isocline: bool,
    lsp: bool,
    mimalloc: bool,
    ffi: bool,
};

/// everything linked into one revo exe, for one target
/// dev and release both go through here
/// dev just names its modules
const Exe = struct {
    vm_mod: *Module,
    revo_mod: *Module,
    c_mod: *Module,
    revolt_mod: *Module,
    exe_mod: *Module,
    erevo_mod: ?*Module,
    ffi_lib: ?*Build.Step.Compile, // for tests
};

fn buildOptionsMod(
    b: *Build,
    git_commit: []const u8,
    perf: bool,
    o: struct {
        is_freestanding: bool,
        mimalloc: bool,
        ffi: bool,
        isocline: bool,
        regex: bool,
        lsp_enabled: bool,
    },
) *Module {
    const opts = b.addOptions();
    opts.addOption(bool, "is_freestanding", o.is_freestanding);
    opts.addOption(bool, "mimalloc", o.mimalloc);
    opts.addOption(bool, "ffi", o.ffi);
    opts.addOption(bool, "isocline", o.isocline);
    opts.addOption(bool, "regex", o.regex);
    opts.addOption([]const u8, "version", VERSION);
    opts.addOption([]const u8, "git_commit", git_commit);
    opts.addOption(bool, "lsp_enabled", o.lsp_enabled);
    opts.addOption(bool, "perf", perf);
    return opts.createModule();
}

fn exeModule(
    b: *Build,
    name: ?[]const u8,
    src: []const u8,
    target: Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    link_libc: bool,
) *Module {
    const opts: Module.CreateOptions = .{
        .root_source_file = b.path(src),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    };
    return if (name) |n| b.addModule(n, opts) else b.createModule(opts);
}

fn makeExe(
    b: *Build,
    o: struct {
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        aux: std.lang.Optimize,
        opts_mod: *Module,
        link_libc: bool,
        named: bool,
        tag: []const u8,
        main_file: []const u8,
        feats: ExeFeatures,
        lsp_mod: ?*Module,
        mimalloc_dep: ?*Build.Dependency,
        ffi_dep: ?*Build.Dependency,
        translate_c_dep: ?*Build.Dependency,
        link_ffi_into_revo: bool, // dev; tests link revo directly
        want_embed: bool,
    },
) !Exe {
    const vm_mod = exeModule(b, if (o.named) "vm" else null, "src/vm/root.zig", o.target, o.optimize, o.link_libc);
    const revo_mod = exeModule(b, if (o.named) "revo" else null, "src/root.zig", o.target, o.optimize, o.link_libc);
    const c_mod = exeModule(b, if (o.named) "capi" else null, "src/capi/root.zig", o.target, o.optimize, o.link_libc);
    const mimalloc_mod = exeModule(b, null, "src/mimalloc.zig", o.target, o.optimize, o.link_libc);

    const isocline_mod = try builds.isocline(b, o.translate_c_dep, o.feats.isocline, o.target, o.aux, o.tag);

    const revolt_mod = b.createModule(.{
        .root_source_file = b.path(if (o.feats.lsp) "src/lsp/server.zig" else "src/lsp/disabled.zig"),
        .target = o.target,
        .optimize = o.aux,
        .link_libc = o.link_libc,
        .imports = if (o.lsp_mod) |lm| &.{
            .{ .name = "lsp", .module = lm },
        } else &.{},
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path(o.main_file),
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = o.link_libc,
        .imports = &.{
            .{ .name = "lsp_main", .module = revolt_mod },
        },
    });

    const erevo_mod: ?*Module = if (o.want_embed)
        exeModule(b, if (o.named) "embed" else null, "src/capi/embed.zig", o.target, o.optimize, o.link_libc)
    else
        null;

    var all: [6]*Module = .{ vm_mod, revo_mod, c_mod, revolt_mod, exe_mod, undefined };
    var n: usize = 5;
    if (erevo_mod) |em| {
        all[5] = em;
        n = 6;
    }
    for (all[0..n]) |m| {
        m.addImport("revo", revo_mod);
        m.addImport("vm", vm_mod);
        m.addImport("capi", c_mod);
        m.addImport("mimalloc", mimalloc_mod);
        m.addImport("build_options", o.opts_mod);
    }

    exe_mod.addImport("isocline", isocline_mod);

    // only linked into artifacts that reference it
    if (o.feats.mimalloc) {
        const mdep = o.mimalloc_dep orelse return error.MimallocDependencyMissing;
        const ml = try builds.mimalloc(b, o.target, o.optimize, mdep);
        exe_mod.linkLibrary(ml);
        if (erevo_mod) |em| em.linkLibrary(ml);
    }

    var ffi_lib: ?*Build.Step.Compile = null;
    if (o.feats.ffi) {
        const tc = o.translate_c_dep orelse return error.TranslateCDependencyMissing;
        // small extern decls over an already-slow call boundary;;; aux is ok
        const c_ffi = builds.translate_c_header(b, tc, "c_ffi", "ffi.h", o.target, o.aux);
        revo_mod.addImport("c_ffi", c_ffi.mod);

        if (o.ffi_dep) |fdep| {
            const lib = fdep.artifact("ffi");
            c_ffi.linkLibrary(lib);
            exe_mod.linkLibrary(lib);

            if (erevo_mod) |em| em.linkLibrary(lib);
            if (o.link_ffi_into_revo) revo_mod.linkLibrary(lib);
            ffi_lib = lib;
        }
    }

    if (o.feats.isocline and o.link_libc) {
        const tc = o.translate_c_dep orelse return error.TranslateCDependencyMissing;
        const c_signal = builds.translate_c_header(b, tc, "c_signal", "signal.h", o.target, o.aux);
        exe_mod.addImport("c_signal", c_signal.mod);
    }

    return .{
        .vm_mod = vm_mod,
        .revo_mod = revo_mod,
        .c_mod = c_mod,
        .revolt_mod = revolt_mod,
        .exe_mod = exe_mod,
        .erevo_mod = erevo_mod,
        .ffi_lib = ffi_lib,
    };
}

pub fn build(b: *Build) !void {
    // Defaults to 'musl' toolchain for linux system because otherwise the build fails with default settings,
    // but not when enabled 'llvm' and 'lld'. -hamza (Jun 14 2026)
    const with_glibc = builtin.target.os.tag == .linux and
        (b.option(bool, "glibc", "build with LLVM and link with glibc") orelse false);

    const with_dynamic = b.option(bool, "dynamic", "force dynamic libc linking if available (warns if unsupported)") orelse true;

    const wasi_cli = b.option(bool, "wasi-cli", "build wasi target as cli (uses wasi syscalls instead of js imports)") orelse false;

    const target = if (builtin.target.os.tag == .linux)
        b.standardTargetOptions(.{ .default_target = if (with_glibc or with_dynamic) .{ .abi = .gnu } else .{ .abi = .musl } })
    else
        b.standardTargetOptions(.{});

    const is_freestanding = target.result.os.tag == .freestanding;
    const is_wasm = target.result.cpu.arch.isWasm();

    const optimize = b.standardOptimizeOption(.{});

    const perf = b.option(bool, "perf", "enable VM perf counters") orelse false;

    // botch: wasm64 has a codegen bug in Debug mode that causes "memory access out of
    // bounds" at runtime for some reason
    // force ReleaseSmall for ALL modules linked into the wasm binary, so the VM code gets the fix too
    const effective_optimize: std.lang.Optimize = if (is_wasm) .small else optimize;
    if (optimize != effective_optimize)
        logger.warn("Debug mode crashes wasm64 builds; forcing ReleaseSmall for all modules", .{});

    const features_str = b.option([]const u8, "features", "available: isocline, lsp, regex, mimalloc, ffi, zig_backend") orelse
        // async is disabled on windows/wasi/freestanding (handled in src/root.zig)
        if (is_freestanding) "" else if (is_wasm) "regex" else "lsp,isocline,regex,mimalloc,ffi";

    // windows can't do ffi (no dlopen); isocline/async degrade at use sites
    const test_filters = b.option([]const []const u8, "test-filter", "only run tests within the arr") orelse &.{};

    const features = getFeatures(features_str);

    const mimalloc_enabled = !is_freestanding and features.mimalloc;
    const ffi_enabled = !is_freestanding and !is_wasm and target.result.os.tag != .windows and features.ffi;

    const aux_optimize: std.lang.Optimize =
        // only the vm gains anything from building with .fast. maybe make this .small for releases?
        if (effective_optimize != .debug) .small else effective_optimize;

    const lsp_kit_dep = if (features.lsp)
        try b.dependencyLazy("lsp_kit", .{ .target = target, .optimize = aux_optimize })
    else
        null;

    const git_result = b.runFallible(&.{ "git", "rev-parse", "--short", "HEAD" }, .{
        .stderr_behavior = .ignore,
    });
    const git_version = switch (git_result) {
        .success => |output| output,
        else => VERSION,
    };

    const dev_version = std.mem.trim(u8, git_version, " \n\r");

    // note: is_freestanding captures top-level, not per-release
    //       this doesnt really matter but it might break something
    const build_options_mod = buildOptionsMod(b, dev_version, perf, .{
        .is_freestanding = is_freestanding,
        .mimalloc = mimalloc_enabled,
        .ffi = ffi_enabled,
        .isocline = features.isocline,
        .regex = features.regex,
        .lsp_enabled = features.lsp,
    });

    //
    // modules (dev; release rebuilds the same per target below)
    //
    // wasi-cli uses cli.zig (wasi syscalls), web uses wasm_entry.zig (js imports)
    const is_wasi_cli = wasi_cli and is_wasm;
    const mimalloc_dep = if (mimalloc_enabled) try b.dependencyLazy("mimalloc", .{}) else null;
    const ffi_dep = if (ffi_enabled) try b.dependencyLazy("libffi", .{
        .target = target,
        .optimize = effective_optimize,
    }) else null;
    const tc_dep = if (ffi_enabled or features.isocline)
        try b.dependencyLazy("translate_c", .{})
    else
        null;

    const exe = try makeExe(b, .{
        .target = target,
        .optimize = effective_optimize,
        .aux = aux_optimize,
        .opts_mod = build_options_mod,
        .link_libc = !is_freestanding,
        .named = true,
        .tag = "dev",
        .main_file = if (is_wasi_cli) "src/cli.zig" else if (is_wasm) "src/wasm_entry.zig" else "src/cli.zig",
        .feats = .{
            .isocline = features.isocline,
            .lsp = features.lsp,
            .mimalloc = mimalloc_enabled,
            .ffi = ffi_enabled,
        },
        .lsp_mod = if (lsp_kit_dep) |dep| dep.module("lsp") else null,
        .mimalloc_dep = mimalloc_dep,
        .ffi_dep = ffi_dep,
        .translate_c_dep = tc_dep,
        .link_ffi_into_revo = true, // tests link revo directly
        .want_embed = !is_freestanding,
    });

    const vm_mod = exe.vm_mod;
    const revo_mod = exe.revo_mod;
    const c_mod = exe.c_mod;
    const revolt_mod = exe.revolt_mod;
    const exe_mod = exe.exe_mod;
    const erevo_mod = exe.erevo_mod;
    const test_ffi_lib = exe.ffi_lib;

    const header_wf = b.addWriteFiles();
    const header_data = bindings.data(b.allocator, VERSION) catch |err| {
        std.debug.print("failed to autogen header\n", .{});
        return err;
    };
    _ = header_wf.add("revo.h", header_data);

    // header_gen unit tests (type mapping, REVO_API emission, dup/export checks)
    const header_gen_mod = exeModule(b, null, "src/capi/header_gen.zig", target, effective_optimize, false);
    const unit_tests = [_]*Build.Step.Compile{
        b.addTest(.{ .root_module = vm_mod, .filters = test_filters }),
        b.addTest(.{ .root_module = revo_mod, .filters = test_filters }),
        b.addTest(.{ .root_module = exe_mod, .filters = test_filters }),
        b.addTest(.{ .root_module = c_mod, .filters = test_filters }),
        b.addTest(.{ .root_module = revolt_mod, .filters = test_filters }),
        b.addTest(.{ .root_module = header_gen_mod, .filters = test_filters }),
    };
    const vm_test = unit_tests[0];
    const revo_test = unit_tests[1];
    const exe_test = unit_tests[2];
    const c_test = unit_tests[3];
    const header_test = unit_tests[5];

    if (is_freestanding or is_wasm) {
        // wasm builds need a larger stack for the dispatch frame;
        // freestanding has no entry point at all
        const wasm_exe = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        if (is_freestanding) wasm_exe.entry = .disabled;
        // the vm dispatch loop's frame alone can exceed the default 1mb size
        wasm_exe.stack_size = 16 * 1024 * 1024;
        wasm_exe.rdynamic = true;
        b.getInstallStep().dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);
    } else {
        const e = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        const lib = b.addLibrary(.{ .name = "erevo", .root_module = erevo_mod.? });

        if (features.zig_backend) {
            // no llvm backend (experimental); both artifacts opt out together
            for ([_]*Build.Step.Compile{ lib, e }) |artifact| {
                artifact.use_llvm = false;
                artifact.use_lld = false;
            }
        }

        if (optimize == .debug) e.lto = .none;
        e.rdynamic = true;

        if (builtin.target.os.tag == .linux and with_glibc) {
            e.use_llvm = true;
            e.use_lld = true;
        }

        const exe_install = b.addInstallArtifact(e, .{});
        const lib_install = b.addInstallArtifact(lib, .{});
        const header_install = b.addInstallDirectory(.{
            .source_dir = header_wf.getDirectory(),
            .install_subdir = "revo",
            .install_dir = .header,
        });
        b.getInstallStep().dependOn(&exe_install.step);
        lib_install.step.dependOn(&header_install.step);

        const lib_step = b.step("lib", "build the erevo library");
        lib_step.dependOn(&lib_install.step);

        //
        // run step
        //
        const run_step = b.step("run", "run the cli");
        {
            const run_exe = b.addRunArtifact(e);
            run_exe.addPassthruArgs();
            run_step.dependOn(&run_exe.step);
        }

        //
        // check step
        //
        const check_step = b.step("check", "type-check without codegen or linking");
        for (unit_tests) |t| check_step.dependOn(&t.step);

        //
        // tests
        //
        const test_step = b.step("test", "run all tests");
        {
            for ([_][]const u8{ "vm", "revo", "exe" }, [_]*Build.Step.Compile{ vm_test, revo_test, exe_test }) |name, t| {
                const s = b.step(b.fmt("test-{s}", .{name}), b.fmt("test only the {s} root", .{name}));
                s.dependOn(&b.addRunArtifact(t).step);
                test_step.dependOn(s);
            }

            test_step.dependOn(&b.addRunArtifact(c_test).step);
            test_step.dependOn(&b.addRunArtifact(header_test).step);

            const test_lang_step = b.step("test-lang", "run the lang suite");
            {
                const mod = exeModule(b, null, "src/lang/tests/root.zig", target, effective_optimize, !is_freestanding);
                mod.addImport("revo", revo_mod);
                if (test_ffi_lib) |ffi| mod.linkLibrary(ffi);
                const t = b.addTest(.{ .root_module = mod, .filters = test_filters });
                const run = b.addRunArtifact(t);

                test_lang_step.dependOn(&run.step);
                test_step.dependOn(&run.step);
            }
        }

        //
        // c test suite
        //
        const test_c_step = b.step("test-c", "run c api tests");
        {
            // shared libs the c suite dlopens at runtime:
            // the extension under test, and a plain-c fixture for ffi e2e
            const dl_libs = [_]struct { name: []const u8, src: []const u8, headers: bool, allow_undef: bool }{
                .{ .name = "revo_test_ext", .src = "examples/foreign/c/extension.c", .headers = true, .allow_undef = true },
                .{ .name = "revo_ffi_fixture", .src = "src/capi/fixture.c", .headers = false, .allow_undef = false },
            };
            var dl_bins: [dl_libs.len]*Build.Step.Compile = undefined;
            for (dl_libs, &dl_bins) |def, *slot| {
                const m = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = !is_freestanding,
                });
                m.addCSourceFile(.{
                    .file = b.path(def.src),
                    .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-fPIC" },
                });
                if (def.headers) m.addIncludePath(header_wf.getDirectory());
                const l = b.addLibrary(.{ .name = def.name, .root_module = m, .linkage = .dynamic });
                l.linker_allow_shlib_undefined = def.allow_undef;
                slot.* = l;
            }

            // the c suite plus a c++ compat build (must compile as c++ and link).
            // only the c suite takes fixture paths (argv[1], argv[2]).
            const c_suites = [_]struct { name: []const u8, src: []const u8, flags: []const []const u8, takes_fixtures: bool }{
                .{ .name = "revo-c-test", .src = "src/capi/tests.c", .flags = &.{ "-std=c99", "-Wall", "-Wextra" }, .takes_fixtures = true },
                .{ .name = "revo-cpp-test", .src = "src/capi/test.cpp", .flags = &.{ "-Wall", "-Wextra" }, .takes_fixtures = false },
            };
            for (c_suites) |suite| {
                const suite_exe = b.addExecutable(.{
                    .name = suite.name,
                    .root_module = b.createModule(.{
                        .target = target,
                        .optimize = optimize,
                        .link_libc = !is_freestanding,
                    }),
                });
                suite_exe.rdynamic = true;
                suite_exe.root_module.addCSourceFile(.{ .file = b.path(suite.src), .flags = suite.flags });
                suite_exe.root_module.addIncludePath(header_wf.getDirectory());
                suite_exe.root_module.linkLibrary(lib);
                suite_exe.root_module.linkSystemLibrary("m", .{ .needed = true });
                if (test_ffi_lib) |fl| suite_exe.root_module.linkLibrary(fl);
                const run = b.addRunArtifact(suite_exe);
                if (suite.takes_fixtures) {
                    run.addFileArg(dl_bins[0].getEmittedBin());
                    run.addFileArg(dl_bins[1].getEmittedBin());
                }
                test_c_step.dependOn(&run.step);
            }
        }
    }

    //
    // release step
    //
    const release_step = b.step("release", "build release binaries for all targets");
    {
        const install_options = Build.Step.InstallArtifact.Options{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        };

        for (release_targets, release_target_queries) |target_def, query| {
            const target_str = target_def.triple;
            const release_target = b.resolveTargetQuery(query);
            const release_is_fs = release_target.result.os.tag == .freestanding;
            const release_is_wasm = release_target.result.cpu.arch.isWasm();
            const release_is_wasi = release_target.result.os.tag == .wasi;
            const release_is_wasi_cli = target_def.wasi_cli;
            const release_optimize: std.lang.Optimize = if (release_is_wasm) .small else .safe;

            const release_lsp_enabled = features.lsp and !release_is_fs;

            // isocline not available on windows, wasi, or freestanding
            const release_isocline_enabled = features.isocline and
                !release_is_fs and
                !release_is_wasi and
                release_target.result.os.tag != .windows;

            const release_ffi_enabled = features.ffi and
                !release_is_fs and
                !release_is_wasm and
                release_target.result.os.tag != .windows;

            // TODO: regex compiles for freestanding, it isn't the issue here
            const rel_options_mod = buildOptionsMod(b, dev_version, perf, .{
                .is_freestanding = release_is_fs,
                .mimalloc = !release_is_fs and mimalloc_enabled,
                .ffi = release_ffi_enabled,
                .isocline = release_isocline_enabled,
                .regex = release_target.result.os.tag != .freestanding and features.regex,
                .lsp_enabled = release_lsp_enabled,
            });

            const rel_lsp_mod: ?*Module = if (release_lsp_enabled)
                if (lsp_kit_dep) |dep| dep.module("lsp") else return error.LspKitDependencyMissing
            else
                null;
            const rel_tc_dep = if (release_ffi_enabled or release_isocline_enabled)
                try b.dependencyLazy("translate_c", .{})
            else
                null;
            const rel_ffi_dep = if (release_ffi_enabled) try b.dependencyLazy("libffi", .{
                .target = release_target,
                .optimize = release_optimize,
            }) else null;

            // wasi-cli uses cli.zig (wasi syscalls), web uses wasm_entry.zig (js imports)
            const rel_exe = try makeExe(b, .{
                .target = release_target,
                .optimize = release_optimize,
                .aux = release_optimize,
                .opts_mod = rel_options_mod,
                .link_libc = !release_is_fs,
                .named = false,
                .tag = b.fmt("release_{s}", .{target_str}),
                .main_file = if (release_is_wasi_cli)
                    "src/cli.zig"
                else if (release_is_wasm)
                    "src/wasm_entry.zig"
                else
                    "src/cli.zig",
                .feats = .{
                    .isocline = release_isocline_enabled,
                    .lsp = release_lsp_enabled,
                    .mimalloc = !release_is_fs and mimalloc_enabled,
                    .ffi = release_ffi_enabled,
                },
                .lsp_mod = rel_lsp_mod,
                .mimalloc_dep = mimalloc_dep,
                .ffi_dep = rel_ffi_dep,
                .translate_c_dep = rel_tc_dep,
                .link_ffi_into_revo = false,
                .want_embed = false,
            });
            const release_mod = rel_exe.exe_mod;

            const release_exe = b.addExecutable(.{
                .name = binName(b, if (release_is_wasi_cli) "wasm32-wasi-cli" else target_str),
                .root_module = release_mod,
            });
            if (release_is_fs or release_is_wasm) {
                if (release_is_fs) release_exe.entry = .disabled;
                // same oversized dispatch frame as the dev wasm build
                release_exe.stack_size = 16 * 1024 * 1024;
            }
            release_exe.rdynamic = true;

            release_step.dependOn(&b.addInstallArtifact(release_exe, install_options).step);
        }
    }
    //
    // lint
    //
    const zlinter = @import("zlinter");
    const lint_cmd = b.step("lint", "lint with zlinter");
    lint_cmd.dependOn(step: {
        // ref:
        // https://github.com/KurtWagner/zlinter/blob/master/RULES.md
        var builder = zlinter.builder(b, .{});
        builder.addRule(.{ .builtin = .field_naming }, .{});
        builder.addRule(.{ .builtin = .declaration_naming }, .{});
        builder.addRule(.{ .builtin = .function_naming }, .{});
        builder.addRule(.{ .builtin = .file_naming }, .{});
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        // autofixable
        builder.addRule(.{ .builtin = .no_unused }, .{});
        // fucks with comments and layouts as of [git blame to check date] dont use
        // builder.addRule(.{ .builtin = .field_ordering }, .{});
        builder.addRule(.{ .builtin = .import_ordering }, .{});
        builder.setCompileUnits(&.{.@"test"});
        break :step builder.build();
    });
    //
    // chore
    //   : fmt, lint, test, markdown fmt
    //
    // an ofa you should run before a commit thats supposed to be 100% correct
    // you really dont have to do it all the time
    //
    // if this passes, your state is very likely correct
    //
    const chore_step = b.step("chore", "run zig fmt, check, lint, tests, c tests, lsp pytest, and rumdl fmt");
    {
        // TODO: when you fix all `zig build lint` suggestions, do both regular lint and autofix
        const chore_cmds = [_][]const []const u8{
            &.{ "zig", "build", "check" },
            &.{ "zig", "build", "lint", "--", "--fix" },
            &.{ "zig", "build", "test", "--error-style", "minimal" },
            &.{ "zig", "build", "test-c", "--error-style", "minimal" },
            &.{ "python3", "-m", "pytest", "src/lsp/test.py", "-v" },
            &.{ "rumdl", "fmt", "./src" },
        };
        var prev: *Build.Step = &b.addFmt(.{ .paths = b.pathList(&.{"./src"}) }).step;
        for (chore_cmds) |argv| {
            const cmd = b.addSystemCommand(argv);
            cmd.step.dependOn(prev);
            prev = &cmd.step;
        }
        chore_step.dependOn(prev);
    }
}
const builds = struct {
    fn translate_c_header(
        b: *Build,
        dep: *Build.Dependency,
        name: []const u8,
        header: []const u8,
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
    ) Translator {
        const stub = b.addWriteFiles().add(
            b.fmt("{s}_stub.h", .{name}),
            b.fmt("#include <{s}>\n", .{header}),
        );
        return .init(dep, .{
            .name = name,
            .c_source_file = stub,
            .target = target,
            .optimize = optimize,
        });
    }

    /// build translate-c mod when enabled else stub
    fn isocline(
        b: *Build,
        translate_c_dep: ?*Build.Dependency,
        enabled: bool,
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        tag: []const u8,
    ) !*Module {
        if (enabled) {
            const isocline_dep = try b.dependencyLazy("isocline", .{});
            const tc_dep = translate_c_dep orelse return error.TranslateCDependencyMissing;
            const translator: Translator = .init(tc_dep, .{
                .c_source_file = isocline_dep.path("include/isocline.h"),
                .target = target,
                .optimize = optimize,
            });
            const mod = translator.mod;
            mod.addCSourceFile(.{
                .file = isocline_dep.path("src/isocline.c"),
                .flags = &.{},
            });
            return mod;
        }

        return b.createModule(.{
            .root_source_file = b.addWriteFiles().add(b.fmt("no_isocline_{s}.zig", .{tag}), ""),
        });
    }

    /// static
    fn mimalloc(
        b: *Build,
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        dep: *Build.Dependency,
    ) !*std.Build.Step.Compile {
        const lib = b.addLibrary(
            .{
                .name = "mimalloc",
                .linkage = .static,
                .use_llvm = true,
                .root_module = b.createModule(
                    .{
                        .target = target,
                        .optimize = optimize,
                        .link_libc = true,
                        .pic = true,
                    },
                ),
            },
        );

        lib.root_module.addIncludePath(dep.path("include"));

        lib.root_module.addCSourceFiles(
            .{
                .root = dep.path("src"),
                .files = &.{
                    "alloc.c",
                    "alloc-aligned.c",
                    "alloc-posix.c",
                    "arena.c",
                    "bitmap.c",
                    "heap.c",
                    "init.c",
                    "libc.c",
                    "options.c",
                    "os.c",
                    "page.c",
                    "random.c",
                    "segment.c",
                    "segment-map.c",
                    "stats.c",
                    "prim/prim.c",
                },
                .flags = if (lib.root_module.optimize != .debug)
                    &.{
                        "-DNDEBUG=1",
                        "-DMI_SECURE=0",
                        "-DMI_STAT=0",
                        "-DMI_SHOW_ERRORS=1",
                        "-DMI_SKIP_COLLECT_ON_EXIT=1",
                        "-fno-sanitize=undefined",
                        "-Wno-date-time",
                    }
                else
                    &.{
                        "-DMI_SKIP_COLLECT_ON_EXIT=1",
                        "-fno-sanitize=undefined",
                        "-Wno-date-time",
                    },
            },
        );

        return lib;
    }
};
