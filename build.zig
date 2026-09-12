const std = @import("std");
const builtin = @import("builtin");
const bindings = @import("src/c/bindings.zig");

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
    .{ .triple = "x86_64-linux-musl" }, // good
    .{ .triple = "aarch64-linux-musl" }, // probably good
    .{ .triple = "x86_64-macos" }, // untested
    .{ .triple = "x86_64-windows" }, // missing dll loading, isocline and async
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

const BinaryType = enum { nightly, release };

fn emptyStr(s: []const u8) bool {
    for (s) |c| switch (c) {
        ' ', '\n', '\r', '\t' => continue,
        else => return false,
    } else return true;
}

fn getFeatures(features: []const u8) Features {
    var ret = Features{};
    if (features.len == 0) return ret;

    var it = std.mem.splitScalar(u8, features, ',');
    while (it.next()) |token| {
        if (emptyStr(token)) continue;

        inline for (@typeInfo(Features).@"struct".fields) |field| {
            if (std.mem.eql(u8, token, field.name)) {
                if (@field(ret, field.name)) {
                    std.log.warn("Duplicate feature: {s}", .{token});
                }
                @field(ret, field.name) = true;
                break;
            }
        } else std.log.warn("Unknown feature: {s}", .{token});
    }
    return ret;
}

/// for release bin names
fn binName(b: *std.Build, triple: []const u8, btype: BinaryType) []const u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{
        .secs = @intCast(std.Io.Clock.real.now(b.graph.io).toSeconds()),
    };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const date_str = b.fmt("{d}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
    return switch (btype) {
        .nightly => b.fmt("revo-nightly-{s}-{s}", .{ triple, date_str }),
        .release => b.fmt("revo-{s}-{s}", .{ VERSION, triple }),
    };
}

pub fn build(b: *Build) !void {
    // Defaults to 'musl' toolchain for linux system because otherwise the build fails with default settings,
    // but not when enabled 'llvm' and 'lld'. -hamza (Jun 14 2026)
    const with_glibc = builtin.os.tag == .linux and
        (b.option(bool, "glibc", "build with LLVM and link with glibc") orelse false);

    const with_dynamic = b.option(bool, "dynamic", "force dynamic libc linking if available (warns if unsupported)") orelse false;
    if (with_dynamic and builtin.os.tag != .linux) {
        logger.warn("-Ddynamic is only meaningful on linux (other platforms already use dynamic libc)", .{});
    }

    const wasi_cli = b.option(bool, "wasi-cli", "build wasi target as cli (uses wasi syscalls instead of js imports)") orelse false;

    const target = if (builtin.os.tag == .linux)
        b.standardTargetOptions(.{ .default_target = if (with_glibc or with_dynamic) .{ .abi = .gnu } else .{ .abi = .musl } })
    else
        b.standardTargetOptions(.{});

    const is_freestanding = target.result.os.tag == .freestanding;
    const is_wasm = target.result.cpu.arch.isWasm();

    const optimize = b.standardOptimizeOption(.{});

    // botch: wasm64 has a codegen bug in Debug mode that causes "memory access out of
    // bounds" at runtime for some reason
    // force ReleaseSmall for ALL modules linked into the wasm binary, so the VM code gets the fix too
    const effective_optimize = if (is_wasm) .ReleaseSmall else optimize;
    if (optimize != effective_optimize)
        logger.warn("Debug mode crashes wasm64 builds; forcing ReleaseSmall for all modules", .{});

    const features_str = b.option([]const u8, "features", "available: isocline, lsp, regex, mimalloc, zig_backend") orelse
        // isocline needs libc and not wasm; wasi gets lsp but not isocline
        // async is disabled on windows/wasi/freestanding (handled in src/root.zig)
        if (is_freestanding) "" else if (is_wasm) "lsp,regex" else "isocline,lsp,regex,mimalloc";

    // windows missing features: isocline (no libc), async (no posix threads)
    if (builtin.os.tag == .windows) {
        if (std.mem.indexOf(u8, features_str, "isocline") != null) {
            logger.warn("isocline is not available on windows, disabling", .{});
        }
    }

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "only run tests within the arr",
    ) orelse &.{};

    const lsp_kit_dep = b.dependency("lsp_kit", .{});
    const mvzr_dep = b.dependency("mvzr", .{});

    const features = getFeatures(features_str);

    const mimalloc_enabled = !is_freestanding and features.mimalloc;

    var git_exit_code: u8 = 0; // ignored, but it's a required argument
    const git_output = b.runAllowFail(
        &.{ "git", "rev-parse", "--short", "HEAD" },
        &git_exit_code,
        .ignore,
    ) catch VERSION;

    const dev_version = std.mem.trim(u8, git_output, " \n\r");

    // used for dev builds
    const debug_options = b.addOptions();
    debug_options.addOption(bool, "is_freestanding", is_freestanding);
    debug_options.addOption(bool, "mimalloc", mimalloc_enabled);
    debug_options.addOption(bool, "isocline", features.isocline);
    debug_options.addOption(bool, "regex", features.regex);
    debug_options.addOption([]const u8, "version", VERSION);
    debug_options.addOption([]const u8, "git_commit", dev_version);
    debug_options.addOption(bool, "lsp_enabled", features.lsp);
    const debug_options_mod = debug_options.createModule();

    // used for release builds
    // note: is_freestanding captures top-level, not per-release.
    // this doesn't really matter but it might break something
    const release_options = b.addOptions();
    release_options.addOption(bool, "is_freestanding", is_freestanding);
    release_options.addOption(bool, "mimalloc", mimalloc_enabled);
    release_options.addOption(bool, "isocline", features.isocline);
    release_options.addOption(bool, "regex", features.regex);
    release_options.addOption([]const u8, "version", VERSION);
    release_options.addOption([]const u8, "git_commit", dev_version);
    release_options.addOption(bool, "lsp_enabled", features.lsp);
    const release_options_mod = release_options.createModule();

    //
    // modules
    //
    const isocline_mod = builds.isocline(b, features.isocline, target, effective_optimize, "dev");
    const vm_mod = b.addModule("vm", .{
        .root_source_file = b.path("src/vm/root.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const revo_mod = b.addModule("revo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const c_mod = b.addModule("c", .{
        .root_source_file = b.path("src/c/root.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const mimalloc_mod = b.createModule(.{
        .root_source_file = b.path("src/mimalloc.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const revolt_mod = b.createModule(.{
        .root_source_file = if (features.lsp)
            b.path("src/lsp/server.zig")
        else
            b.path("src/lsp/noop.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
        .imports = if (features.lsp) &.{
            .{ .name = "lsp", .module = lsp_kit_dep.module("lsp") },
        } else &.{},
    });
    // wasi-cli uses main.zig (wasi syscalls), web uses main_wasm.zig (js imports)
    const is_wasi_cli = wasi_cli and is_wasm;
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(if (is_wasi_cli) "src/main.zig" else if (is_wasm) "src/main_wasm.zig" else "src/main.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
        .imports = &.{
            .{ .name = "lsp_main", .module = revolt_mod },
        },
    });
    const erevo_mod = if (!is_freestanding)
        b.addModule("erevo", .{
            .root_source_file = b.path("src/c/erevo.zig"),
            .target = target,
            .optimize = effective_optimize,
            .link_libc = !is_freestanding,
        })
    else
        null;

    const all_mods: []const *Module = if (is_freestanding) &.{
        vm_mod,  revo_mod,
        c_mod,   revolt_mod,
        exe_mod,
    } else &.{
        vm_mod,  revo_mod,
        c_mod,   revolt_mod,
        exe_mod, erevo_mod.?,
    };
    var import_list: std.ArrayListUnmanaged(Module.Import) = .empty;
    defer import_list.deinit(b.allocator);
    try import_list.append(b.allocator, .{ .name = "revo", .module = revo_mod });
    try import_list.append(b.allocator, .{ .name = "vm", .module = vm_mod });
    try import_list.append(b.allocator, .{ .name = "c", .module = c_mod });
    // shouldn't get compiled in if regex flag unspecified
    try import_list.append(b.allocator, .{
        .name = "mvzr",
        .module = builds.mvzr(b, mvzr_dep, target, effective_optimize),
    });
    try import_list.append(b.allocator, .{ .name = "mimalloc", .module = mimalloc_mod });
    const imports = try import_list.toOwnedSlice(b.allocator);
    const shared_build_options = if (optimize == .Debug) debug_options_mod else release_options_mod;
    for (all_mods) |mod| {
        for (imports) |imp| {
            mod.addImport(imp.name, imp.module);
        }
        mod.addImport("build_options", shared_build_options);
    }

    exe_mod.addImport("isocline", isocline_mod);

    // only linked into artifacts that reference it
    const mimalloc_dep = if (mimalloc_enabled) b.lazyDependency("mimalloc", .{}) else null;
    const mimalloc_lib = if (mimalloc_dep) |dep|
        try builds.mimalloc(b, target, effective_optimize, dep)
    else
        null;
    if (mimalloc_lib) |ml| {
        exe_mod.linkLibrary(ml);
        if (erevo_mod) |em| em.linkLibrary(ml);
    }

    const header_wf = b.addWriteFiles();
    const header_data = bindings.data(b.allocator) catch |err| {
        std.debug.print("failed to autogen header\n", .{});
        return err;
    };
    _ = header_wf.add("revo.h", header_data.items);

    const vm_test = b.addTest(.{ .root_module = vm_mod, .filters = test_filters });
    const revo_test = b.addTest(.{ .root_module = revo_mod, .filters = test_filters });
    const exe_test = b.addTest(.{ .root_module = exe_mod, .filters = test_filters });
    const c_test = b.addTest(.{ .root_module = c_mod, .filters = test_filters });
    const revolt_test = b.addTest(.{ .root_module = revolt_mod, .filters = test_filters });

    if (is_freestanding) {
        const wasm_lib = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        wasm_lib.entry = .disabled;
        wasm_lib.rdynamic = true;
        // the vm dispatch loop's frame alone can exceed the default 1mb size in ReleaseSafe
        wasm_lib.stack_size = 16 * 1024 * 1024;
        const wasm_install = b.addInstallArtifact(wasm_lib, .{});
        b.getInstallStep().dependOn(&wasm_install.step);
    } else if (is_wasm) {
        // wasm builds (wasi-cli) need larger stack for dispatch frame
        // yes its that big lol my bad
        const wasm_exe = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        wasm_exe.stack_size = 16 * 1024 * 1024;
        wasm_exe.rdynamic = true;
        const wasm_install = b.addInstallArtifact(wasm_exe, .{});
        b.getInstallStep().dependOn(&wasm_install.step);
    } else {
        const exe = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        const lib = b.addLibrary(.{ .name = "erevo", .root_module = erevo_mod.? });

        if (features.zig_backend) {
            lib.use_llvm = false;
            lib.use_lld = false;
        }

        if (optimize == .Debug) exe.lto = .none;
        exe.rdynamic = true;
        if (features.zig_backend) exe.use_llvm = false;
        if (features.zig_backend) exe.use_lld = false;
        if (builtin.os.tag == .linux and with_glibc) {
            exe.use_llvm = true;
            exe.use_lld = true;
        }

        const exe_install = b.addInstallArtifact(exe, .{});
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
            const run_exe = b.addRunArtifact(exe);
            run_exe.addArgs(b.args orelse &.{});
            run_step.dependOn(&run_exe.step);
        }

        //
        // check step
        //
        const check_step = b.step("check", "type-check without codegen or linking");
        check_step.dependOn(&vm_test.step);
        check_step.dependOn(&revo_test.step);
        check_step.dependOn(&exe_test.step);
        check_step.dependOn(&c_test.step);
        check_step.dependOn(&revolt_test.step);

        //
        // tests
        //
        const test_step = b.step("test", "run all tests");
        {
            const test_vm_step = b.step("test-vm", "test only the vm module");
            test_vm_step.dependOn(&b.addRunArtifact(vm_test).step);
            test_step.dependOn(test_vm_step);

            const test_revo_step = b.step("test-revo", "test only the revo module");
            test_revo_step.dependOn(&b.addRunArtifact(revo_test).step);
            test_step.dependOn(test_revo_step);

            const test_exe_step = b.step("test-exe", "test only the exe root");
            test_exe_step.dependOn(&b.addRunArtifact(exe_test).step);
            test_step.dependOn(test_exe_step);

            test_step.dependOn(&b.addRunArtifact(c_test).step);
        }

        //
        // c test suite
        //
        const test_c_step = b.step("test-c", "run c api tests");
        {
            const c_test_exe = b.addExecutable(.{
                .name = "revo-c-test",
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = !is_freestanding,
                }),
            });
            c_test_exe.root_module.addCSourceFile(.{
                .file = b.path("src/c/tests.c"),
                .flags = &.{
                    "-std=c99", "-Wall", "-Wextra",
                },
            });
            c_test_exe.root_module.addIncludePath(header_wf.getDirectory());
            c_test_exe.root_module.linkLibrary(lib);
            c_test_exe.root_module.linkSystemLibrary("m", .{ .needed = true });

            const c_test_run = b.addRunArtifact(c_test_exe);
            test_c_step.dependOn(&c_test_run.step);
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
            const release_optimize: std.builtin.OptimizeMode = if (release_is_wasm) .ReleaseSmall else .ReleaseSafe;

            const release_lsp_enabled = features.lsp and !release_is_fs;
            // isocline not available on windows, wasi, or freestanding
            const release_isocline_enabled = features.isocline and !release_is_fs and !release_is_wasi and builtin.os.tag != .windows;

            const rel_options = b.addOptions();
            rel_options.addOption(bool, "is_freestanding", release_is_fs);
            rel_options.addOption(bool, "mimalloc", !release_is_fs and mimalloc_enabled);
            rel_options.addOption(bool, "isocline", release_isocline_enabled);
            // TODO: regex compiles for freestanding, it isn't the issue here
            rel_options.addOption(
                bool,
                "regex",
                release_target.result.os.tag != .freestanding and features.regex,
            );
            rel_options.addOption([]const u8, "version", VERSION);
            rel_options.addOption([]const u8, "git_commit", dev_version);
            rel_options.addOption(bool, "lsp_enabled", release_lsp_enabled);
            const rel_options_mod = rel_options.createModule();

            const rel_vm_mod = b.createModule(.{
                .root_source_file = b.path("src/vm/root.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });
            const rel_revo_mod = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });
            const rel_c_mod = b.createModule(.{
                .root_source_file = b.path("src/c/root.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });

            const rel_mvzr_mod = builds.mvzr(b, mvzr_dep, release_target, release_optimize);
            const rel_mimalloc_mod = b.createModule(.{
                .root_source_file = b.path("src/mimalloc.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });
            const rel_core_mods: []const *Module = &.{ rel_vm_mod, rel_revo_mod, rel_c_mod };
            for (rel_core_mods) |mod| {
                mod.addImport("revo", rel_revo_mod);
                mod.addImport("vm", rel_vm_mod);
                mod.addImport("c", rel_c_mod);
                mod.addImport("mvzr", rel_mvzr_mod);
                mod.addImport("build_options", rel_options_mod);
            }

            const rel_isocline_mod = builds.isocline(
                b,
                release_isocline_enabled,
                release_target,
                release_optimize,
                b.fmt("release_{s}", .{target_str}),
            );

            const rel_revolt_mod = b.createModule(.{
                .root_source_file = if (release_lsp_enabled)
                    b.path("src/lsp/server.zig")
                else
                    b.path("src/lsp/noop.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
                .imports = if (release_lsp_enabled) &[_]Module.Import{
                    .{ .name = "revo", .module = rel_revo_mod },
                    .{ .name = "vm", .module = rel_vm_mod },
                    .{ .name = "c", .module = rel_c_mod },
                    .{ .name = "build_options", .module = rel_options_mod },
                    .{ .name = "lsp", .module = lsp_kit_dep.module("lsp") },
                } else &.{},
            });

            // wasi-cli uses main.zig (wasi syscalls), web uses main_wasm.zig (js imports)
            const release_main_file = if (release_is_wasi_cli)
                "src/main.zig"
            else if (release_is_wasm)
                "src/main_wasm.zig"
            else
                "src/main.zig";

            const release_mod = b.createModule(.{
                .root_source_file = b.path(release_main_file),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
                .imports = &[_]Module.Import{
                    .{ .name = "revo", .module = rel_revo_mod },
                    .{ .name = "vm", .module = rel_vm_mod },
                    .{ .name = "c", .module = rel_c_mod },
                    .{ .name = "build_options", .module = rel_options_mod },
                    .{ .name = "isocline", .module = rel_isocline_mod },
                    .{ .name = "mimalloc", .module = rel_mimalloc_mod },
                    .{ .name = "lsp_main", .module = rel_revolt_mod },
                },
            });

            if (!release_is_fs and mimalloc_enabled) {
                const rel_mimalloc = try builds.mimalloc(b, release_target, release_optimize, mimalloc_dep.?);
                release_mod.linkLibrary(rel_mimalloc);
            }

            const release_exe = b.addExecutable(.{
                .name = if (release_is_wasi_cli)
                    binName(b, "wasm32-wasi-cli", .release)
                else
                    binName(b, target_str, .release),
                .root_module = release_mod,
            });
            if (release_is_fs) {
                release_exe.entry = .disabled;
                // same oversized dispatch frame as the dev wasm build
                release_exe.stack_size = 16 * 1024 * 1024;
            } else if (release_is_wasm) {
                // wasm builds need larger stack for dispatch frame
                release_exe.stack_size = 16 * 1024 * 1024;
            }
            release_exe.rdynamic = true;

            release_step.dependOn(&b.addInstallArtifact(release_exe, install_options).step);
        }
    }
}
const builds = struct {
    fn mvzr(
        b: *Build,
        mvzr_dep: *Build.Dependency,
        target: Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) *Module {
        return b.createModule(.{
            .root_source_file = mvzr_dep.path("src/mvzr.zig"),
            .target = target,
            .optimize = optimize,
        });
    }

    /// build translate-c mod when enabled else stub
    fn isocline(
        b: *Build,
        enabled: bool,
        target: Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        tag: []const u8,
    ) *Module {
        if (enabled) {
            if (b.lazyDependency("isocline", .{})) |isocline_dep| {
                const isocline_c = b.addTranslateC(.{
                    .root_source_file = isocline_dep.path("include/isocline.h"),
                    .target = target,
                    .optimize = optimize,
                });
                isocline_c.addIncludePath(isocline_dep.path("include/"));
                const mod = isocline_c.createModule();
                mod.addCSourceFile(.{
                    .file = isocline_dep.path("src/isocline.c"),
                    .flags = &.{},
                });
                return mod;
            }
        }

        return b.createModule(.{
            .root_source_file = b.addWriteFiles().add(b.fmt("no_isocline_{s}.zig", .{tag}), ""),
        });
    }

    /// static
    fn mimalloc(
        b: *Build,
        target: Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
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
                .flags = if (lib.root_module.optimize != .Debug)
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
