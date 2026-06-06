const std = @import("std");

const VERSION = "0.0.1a";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // none left in for compat & embed
    const ReplBackend = enum { isocline, none };
    const repl_backend = b.option(ReplBackend, "repl", "which repl backend to use") orelse .isocline;

    const nolsp = b.option(bool, "nolsp", "Exclude the LSP server from the binary") orelse false;
    const bundle_lsp = !nolsp and optimize != .Debug;

    const build_options = b.addOptions();
    build_options.addOption(ReplBackend, "repl_backend", repl_backend);
    build_options.addOption([]const u8, "version", VERSION);
    build_options.addOption(bool, "lsp_enabled", bundle_lsp);

    // release/run always force isocline
    const forced_build_options = b.addOptions();
    forced_build_options.addOption(ReplBackend, "repl_backend", .isocline);
    forced_build_options.addOption([]const u8, "version", VERSION);
    forced_build_options.addOption(bool, "lsp_enabled", !nolsp);

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
    const all_mods = [_]*std.Build.Module{ vm_mod, revo_mod };
    const imports = [_]struct { []const u8, *std.Build.Module }{
        .{ "revo", revo_mod },
        .{ "vm", vm_mod },
    };
    for (all_mods) |mod|
        for (imports) |imp|
            mod.addImport(imp[0], imp[1]);

    const test_filters = b.option(
        []const []const u8,
        "test_filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const is_freestanding = target.result.os.tag == .freestanding;

    //
    // git submodule update for all Doptimize!=Debug
    //
    const maybe_git_submod: ?*std.Build.Step = blk: {
        const stamp = ".zig-cache/submodules-updated";
        const cmd = b.addSystemCommand(&.{
            "sh", "-c",
            b.fmt(
                // so that fetch is nop on rebuild
                "[ {s} -nt .gitmodules ] || (git submodule update --init --recursive && touch {s})",
                .{ stamp, stamp },
            ),
        });
        break :blk &cmd.step;
    };

    //
    // main exe
    //
    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_freestanding,
    });

    if (!is_freestanding) {
        if (repl_backend == .isocline) {
            add_isocline(exe_root, b);
        }

        exe_root.addOptions("build_options", build_options);
    }

    for (imports) |imp| exe_root.addImport(imp[0], imp[1]);

    if (bundle_lsp) {
        if (b.lazyDependency("lsp_kit", .{})) |lsp_kit_dep| {
            const lsp_mod = lsp_kit_dep.module("lsp");

            const lsp_server_mod = b.createModule(.{
                .root_source_file = b.path("src/lsp/server.zig"),
                .target = target,
                .optimize = optimize,
            });
            lsp_server_mod.addImport("lsp", lsp_mod);
            for (imports) |imp| lsp_server_mod.addImport(imp[0], imp[1]);
            exe_root.addImport("lsp_main", lsp_server_mod);
        } else {
            // lsp_kit not fetched yet; use noop stub. maybe there's a better way of doing this, idk
            std.debug.print("warning: lsp_kit not fetched, LSP won't be bundled. run zig build --fetch if you need it\n", .{});
            const lsp_noop_mod = b.createModule(.{
                .root_source_file = b.path("src/lsp/noop.zig"),
                .target = target,
                .optimize = optimize,
            });
            lsp_noop_mod.addImport("revo", revo_mod);
            exe_root.addImport("lsp_main", lsp_noop_mod);
        }
    } else {
        const lsp_noop_mod = b.createModule(.{
            .root_source_file = b.path("src/lsp/noop.zig"),
            .target = target,
            .optimize = optimize,
        });
        lsp_noop_mod.addImport("revo", revo_mod);
        exe_root.addImport("lsp_main", lsp_noop_mod);
    }

    const exe = b.addExecutable(.{ .name = "revo", .root_module = exe_root });
    if (optimize == .Debug) exe.lto = .none;
    exe.rdynamic = true;

    const install_exe = b.addInstallArtifact(exe, .{});
    if (maybe_git_submod) |git_step| install_exe.step.dependOn(git_step);
    b.getInstallStep().dependOn(&install_exe.step);

    //
    // run step
    //
    const run_cmd = b.addRunArtifact(exe);
    if (maybe_git_submod) |git_step| run_cmd.step.dependOn(git_step);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "run the cli").dependOn(&run_cmd.step);

    //
    // check step
    //
    const check_step = b.step("check", "type-check without codegen or linking");
    if (maybe_git_submod) |git_step| check_step.dependOn(git_step);

    //
    // tests
    //
    const test_step = b.step("test", "run all tests");

    const test_vm_step = b.step("test-vm", "test only the vm module");
    const vm_test = b.addTest(.{ .root_module = vm_mod, .filters = test_filters });
    test_vm_step.dependOn(&b.addRunArtifact(vm_test).step);
    check_step.dependOn(&b.addTest(.{ .root_module = vm_mod, .filters = test_filters }).step);

    const test_revo_step = b.step("test-revo", "test only the revo module");
    const revo_test = b.addTest(.{ .root_module = revo_mod, .filters = test_filters });
    test_revo_step.dependOn(&b.addRunArtifact(revo_test).step);
    check_step.dependOn(&b.addTest(.{ .root_module = revo_mod, .filters = test_filters }).step);

    const test_exe_step = b.step("test-exe", "test only the exe root");
    const exe_test = b.addTest(.{ .root_module = exe_root, .filters = test_filters });
    test_exe_step.dependOn(&b.addRunArtifact(exe_test).step);
    check_step.dependOn(&b.addTest(.{ .root_module = exe_root, .filters = test_filters }).step);

    test_step.dependOn(test_vm_step);
    test_step.dependOn(test_revo_step);
    test_step.dependOn(test_exe_step);

    //
    // releases
    //
    const release_targets: []const []const u8 = &.{
        "x86_64-linux-musl",
        // "aarch64-linux-musl",
        // "x86_64-macos",
        "aarch64-macos",
        // "x86_64-windows",
    };

    const release_step = b.step("release", "build release binaries for all targets");

    // release is always non-Debug so always update submodules w\ stamp file
    const git_submod_release = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "[ .zig-cache/submodules-updated -nt .gitmodules ] || (git submodule update --init --recursive && touch .zig-cache/submodules-updated)",
            .{},
        ),
    });

    for (release_targets) |target_str| {
        const release_target = b.resolveTargetQuery(
            std.Target.Query.parse(.{ .arch_os_abi = target_str }) catch |err| {
                std.debug.panic("invalid target '{s}': {}", .{ target_str, err });
            },
        );

        const release_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = release_target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });

        add_isocline(release_mod, b);
        // forced_build_options: release always uses isocline
        release_mod.addOptions("build_options", forced_build_options);
        for (imports) |imp| release_mod.addImport(imp[0], imp[1]);

        if (!nolsp) {
            if (b.lazyDependency("lsp_kit", .{})) |lsp_kit_dep_release| {
                const lsp_mod_release = lsp_kit_dep_release.module("lsp");
                const lsp_server_mod_release = b.createModule(.{
                    .root_source_file = b.path("src/lsp/server.zig"),
                    .target = release_target,
                    .optimize = .ReleaseFast,
                });
                lsp_server_mod_release.addImport("lsp", lsp_mod_release);
                for (imports) |imp| lsp_server_mod_release.addImport(imp[0], imp[1]);
                release_mod.addImport("lsp_main", lsp_server_mod_release);
            } else {
                const lsp_noop_mod_release = b.createModule(.{
                    .root_source_file = b.path("src/lsp/noop.zig"),
                    .target = release_target,
                    .optimize = .ReleaseFast,
                });
                lsp_noop_mod_release.addImport("revo", revo_mod);
                release_mod.addImport("lsp_main", lsp_noop_mod_release);
            }
        } else {
            const lsp_noop_mod_release = b.createModule(.{
                .root_source_file = b.path("src/lsp/noop.zig"),
                .target = release_target,
                .optimize = .ReleaseFast,
            });
            lsp_noop_mod_release.addImport("revo", revo_mod);
            release_mod.addImport("lsp_main", lsp_noop_mod_release);
        }

        const bin_name = b.fmt("revo-{s}-{s}", .{ VERSION, target_str });
        const release_exe = b.addExecutable(.{
            .name = bin_name,
            .root_module = release_mod,
        });

        const install = b.addInstallArtifact(release_exe, .{});
        install.step.dependOn(&git_submod_release.step);
        release_step.dependOn(&install.step);
    }

    //
    // erevo library
    //
    const erevo_mod = b.addModule("erevo", .{
        .root_source_file = b.path("src/erevo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (imports) |imp| erevo_mod.addImport(imp[0], imp[1]);

    const lib = b.addLibrary(.{
        .name = "erevo",
        .root_module = erevo_mod,
    });

    const lib_step = b.step("lib", "build the erevo library");
    const install_lib = b.addInstallArtifact(lib, .{});
    if (maybe_git_submod) |git_step| install_lib.step.dependOn(git_step);
    lib_step.dependOn(&install_lib.step);

    // also cover erevo in check step (maybe possibly dont)
    // check_step.dependOn(&b.addTest(.{ .root_module = erevo_mod, .filters = test_filters }).step);
    // const test_erevo_step = b.step("test-erevo", "test only the erevo library");
    // test_erevo_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = erevo_mod, .filters = test_filters })).step);
    // test_step.dependOn(test_erevo_step);

    //
    // lsp
    //
    if (b.lazyDependency("lsp_kit", .{})) |lsp_kit_dep| {
        const lsp_mod = lsp_kit_dep.module("lsp");

        const revolt_root = b.createModule(.{
            .root_source_file = b.path("src/lsp/server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        revolt_root.addImport("lsp", lsp_mod);
        for (imports) |imp| revolt_root.addImport(imp[0], imp[1]);

        const revolt = b.addExecutable(.{ .name = "revolt", .root_module = revolt_root });
        const install_revolt = b.addInstallArtifact(revolt, .{});

        const revolt_step = b.step("lsp", "build the lsp");
        revolt_step.dependOn(&install_revolt.step);
    }

    const write_files = b.addWriteFiles();
    const bindings = @import("src/bindings.zig");
    const header_data = bindings.data(b.allocator) catch |err| {
        std.debug.print("failed to autogen header: {any}\n", .{err});
        std.process.exit(1);
    };
    const header_path = write_files.add("revo.h", header_data.items);

    const install_header_file = b.addInstallHeaderFile(header_path, "revo.h");
    install_header_file.step.dependOn(&write_files.step);
    lib_step.dependOn(&install_header_file.step);
}

fn add_isocline(mod: *std.Build.Module, b: *std.Build) void {
    mod.addCSourceFile(.{
        .file = b.path("deps/isocline/src/isocline.c"),
        .flags = &.{},
    });
    mod.addIncludePath(b.path("deps/isocline/include"));
}
