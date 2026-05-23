const std = @import("std");

const VERSION = "0.0.1a";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ReplBackend = enum { libedit, readline, bestline, none };
    const repl_backend = b.option(ReplBackend, "repl", "which repl backend to use") orelse .bestline;

    const build_options = b.addOptions();
    build_options.addOption(ReplBackend, "repl_backend", repl_backend);
    build_options.addOption([]const u8, "version", VERSION);

    const vm_mod = b.addModule("vm", .{
        .root_source_file = b.path("src/vm/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const revo_mod = b.addModule("revo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
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
    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_freestanding,
    });

    // even without the if stmt it costs nothing when compiled in when a different backend is avaliable
    // i genuinely dont know why
    if (!is_freestanding) {
        if (repl_backend == .bestline) {
            exe_root.addCSourceFile(.{
                .file = b.path("vendor/bestline.c"),
                .flags = &.{},
            });
            exe_root.addIncludePath(b.path("vendor"));
        }

        // get via @import("build_options").
        exe_root.addOptions("build_options", build_options);

        switch (repl_backend) {
            .libedit => exe_root.linkSystemLibrary("edit", .{ .preferred_link_mode = .dynamic }),
            .readline => exe_root.linkSystemLibrary("readline", .{ .preferred_link_mode = .dynamic }),
            .bestline => {},
            .none => {},
        }
    }

    for (imports) |imp| exe_root.addImport(imp[0], imp[1]);

    const exe = b.addExecutable(.{ .name = "revo", .root_module = exe_root });
    b.installArtifact(exe);

    // run exe code is duped to make it not link with a line editor even explicitly
    // TODO make it link with a line editor when specified explicitly
    const run_exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_build_options = b.addOptions();
    run_build_options.addOption(ReplBackend, "repl_backend", .none);
    run_build_options.addOption([]const u8, "version", VERSION);
    if (!is_freestanding) {
        run_exe_root.addOptions("build_options", run_build_options);
    }
    for (imports) |imp| run_exe_root.addImport(imp[0], imp[1]);

    const run_exe = b.addExecutable(.{ .name = "revo-run", .root_module = run_exe_root });

    const run_cmd = b.addRunArtifact(run_exe);

    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "run the cli").dependOn(&run_cmd.step);

    const check_modules = [_]*std.Build.Module{ revo_mod, vm_mod, exe_root };

    const test_step = b.step("test", "run all tests");
    for (check_modules) |mod| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .root_module = mod,
            .filters = test_filters,
        })).step);
    }

    const check_step = b.step("check", "compile the project without running it");
    check_step.dependOn(&b.addExecutable(.{ .name = "revo-check", .root_module = exe_root }).step);
    for (check_modules) |mod| {
        check_step.dependOn(&b.addTest(.{ .root_module = mod, .filters = test_filters }).step);
    }
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

        release_mod.addCSourceFile(.{
            .file = b.path("vendor/bestline.c"),
            .flags = &.{},
        });
        release_mod.addIncludePath(b.path("vendor"));
        release_mod.addOptions("build_options", build_options);
        for (imports) |imp| release_mod.addImport(imp[0], imp[1]);

        const bin_name = b.fmt("revo-{s}-{s}", .{ VERSION, target_str });
        const release_exe = b.addExecutable(.{
            .name = bin_name,
            .root_module = release_mod,
        });

        const install = b.addInstallArtifact(release_exe, .{});
        release_step.dependOn(&install.step);
    }

    const erevo_mod = b.addModule("erevo", .{
        .root_source_file = b.path("src/erevo.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (imports) |imp| erevo_mod.addImport(imp[0], imp[1]);

    const lib = b.addLibrary(.{
        .name = "erevo",
        .root_module = erevo_mod,
    });

    const lib_step = b.step("lib", "build the erevo library");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);

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
