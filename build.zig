const std = @import("std");
const builtin = @import("builtin");
const bindings = @import("src/c/bindings.zig");

const Build = std.Build;
const Module = Build.Module;
const logger = std.log.scoped(.@"build/revo");

const VERSION = "0.0.0";
const release_targets: []const []const u8 = &.{
    "x86_64-linux-musl",
    // "aarch64-linux-musl",
    // "x86_64-macos",
    "aarch64-macos",
    "x86_64-windows",
};
const release_target_queries = blk: {
    @setEvalBranchQuota(10_000);
    // pre-computes queries
    var arr: [release_targets.len]std.Target.Query = undefined;
    var bad_targets: []const u8 = &.{};
    for (release_targets, &arr) |in, *out| {
        out.* = std.Target.Query.parse(.{ .arch_os_abi = in }) catch {
            if (bad_targets.len >= 1) {
                bad_targets = bad_targets ++ ", ";
            }
            bad_targets = bad_targets ++ "\"" ++ in ++ "\"";
        };
    }
    if (bad_targets.len >= 1) {
        @compileError("Invalid target(s): " ++ bad_targets);
    }

    const c_arr = arr;
    break :blk &c_arr;
};

const Features = packed struct {
    isocline: bool = false,
    lsp: bool = false,

    fn isFull(self: Features) bool {
        const info = @typeInfo(Features).@"struct";
        const BackInt = info.backing_integer.?;
        return @popCount(@as(BackInt, @bitCast(self))) == @bitSizeOf(BackInt);
    }
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
    var target: std.Build.ResolvedTarget = undefined;
    // Defaults to 'musl' toolchain for linux system because otherwise the build fails with default settings,
    // but not when enabled 'llvm' and 'lld'. -hamza (Jun 14 2026)
    var with_glibc: bool = undefined;
    if (builtin.os.tag == .linux) {
        with_glibc = b.option(bool, "glibc", "Build with llvm and link with glibc") orelse false;
        if (with_glibc) {
            target = b.standardTargetOptions(.{.default_target = .{ .abi = .musl }});
        } else {
            target = b.standardTargetOptions(.{.default_target = .{ .abi = .gnu }});
        }
    } else {
        target = b.standardTargetOptions(.{});
    }

    const optimize = b.standardOptimizeOption(.{});

    const features_str = b.option([]const u8, "features", "available: isocline, lsp") orelse "isocline,lsp";
    const do_release = b.option(bool, "release", "Build release binaries for all targets") orelse false;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "only run tests within the arr",
    ) orelse &.{};

    const lsp_kit_dep = b.dependency("lsp_kit", .{});

    const features = getFeatures(features_str);

    var git_exit_code: u8 = 0; // ignored, but it's a required argument
    const git_output = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &git_exit_code, .ignore) catch VERSION;
    const dev_version = std.mem.trim(u8, git_output, " \n\r");

    // used for dev builds
    const debug_options = b.addOptions();
    debug_options.addOption(bool, "isocline", features.isocline);
    debug_options.addOption([]const u8, "version", dev_version);
    debug_options.addOption(bool, "lsp_enabled", features.lsp);
    const debug_options_mod = debug_options.createModule();

    // used for release builds
    const release_options = b.addOptions();
    release_options.addOption(bool, "isocline", features.isocline);
    release_options.addOption([]const u8, "version", VERSION);
    release_options.addOption(bool, "lsp_enabled", features.lsp);
    const release_options_mod = release_options.createModule();

    const is_freestanding = target.result.os.tag == .freestanding;

    //
    // modules
    //
    const isocline_mod = blk: {
        if (features.isocline) {
            if (b.lazyDependency("isocline", .{})) |isocline_dep| {
                const ioscline_c = b.addTranslateC(.{
                    .root_source_file = isocline_dep.path("include/isocline.h"),
                    .target = target,
                    .optimize = optimize,
                });
                ioscline_c.addIncludePath(isocline_dep.path("include/"));
                const isocline_mod = ioscline_c.createModule();
                isocline_mod.addCSourceFile(.{
                    .file = isocline_dep.path("src/isocline.c"),
                    .flags = &.{},
                });

                break :blk isocline_mod;
            }
        }

        break :blk b.createModule(.{ .root_source_file = b.addWriteFiles().add("no_isocline.zig", "") });
    };
    const vm_mod = b.addModule("vm", .{
        .root_source_file = b.path("src/vm/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const revo_mod = b.addModule("revo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_mod = b.addModule("c", .{
        .root_source_file = b.path("src/c/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const revolt_mod = b.createModule(.{
        .root_source_file = if (features.lsp)
            b.path("src/lsp/server.zig")
        else
            b.path("src/lsp/noop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_kit_dep.module("lsp") },
        },
    });
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_freestanding,
        .imports = &.{
            .{ .name = "lsp_main", .module = revolt_mod },
        },
    });
    const erevo_mod = b.addModule("erevo", .{
        .root_source_file = b.path("src/c/erevo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const all_mods = [_]*Module{
        vm_mod,  revo_mod,
        c_mod,   revolt_mod,
        exe_mod, erevo_mod,
    };
    const imports = [_]Module.Import{
        .{ .name = "revo", .module = revo_mod },
        .{ .name = "vm", .module = vm_mod },
        .{ .name = "c", .module = c_mod },
    };
    for (all_mods) |mod| {
        for (imports) |imp| {
            mod.addImport(imp.name, imp.module);
        }
    }

    exe_mod.addImport("isocline", isocline_mod);
    if (!is_freestanding) {
        exe_mod.addImport("build_options", if (optimize == .Debug) debug_options_mod else release_options_mod);
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

    const exe = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
    const lib = b.addLibrary(.{ .name = "erevo", .root_module = erevo_mod });

    if (optimize == .Debug) exe.lto = .none;
    exe.rdynamic = true; // Expose exports to dynamic libraries
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
                .link_libc = true,
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

    //
    // releases
    //
    if (do_release) {
        const install_options = Build.Step.InstallArtifact.Options{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        };

        for (release_targets, release_target_queries) |target_str, query| {
            const release_target = b.resolveTargetQuery(query);

            const rel_revolt_mod = b.createModule(.{
                .root_source_file = if (features.lsp)
                    b.path("src/lsp/server.zig")
                else
                    b.path("src/lsp/noop.zig"),
                .target = release_target,
                .optimize = .ReleaseFast,
                .link_libc = true,
                .imports = &(imports ++ [_]Module.Import{
                    .{ .name = "lsp", .module = lsp_kit_dep.module("lsp") },
                }),
            });

            const release_mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = release_target,
                .optimize = .ReleaseFast,
                .link_libc = true,
                .imports = &(imports ++ [_]Module.Import{
                    .{ .name = "isocline", .module = isocline_mod },
                    .{ .name = "build_options", .module = release_options_mod },
                    .{ .name = "lsp_main", .module = rel_revolt_mod },
                }),
            });

            const release_exe = b.addExecutable(.{
                .name = binName(b, target_str, .nightly),
                .root_module = release_mod,
            });
            release_exe.rdynamic = true;

            b.getInstallStep().dependOn(&b.addInstallArtifact(release_exe, install_options).step);
        }
    }
}
