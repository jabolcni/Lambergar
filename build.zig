const std = @import("std");
const builtin = @import("builtin");

// zig build --release=fast
// zig build -Dtarget=x86_64-windows -Dcpu=haswell --release=fast
// zig build -Dtarget=x86_64-windows -Dcpu=raptorlake --release=fast
// zig build -Dtarget=x86_64-windows --release=fast
// zig build -Dtarget=x86_64-linux --release=fast
// zig build -Dtarget=aarch64-macos -Dcpu=apple_m1 --release=fast

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.

    //const optimize = b.standardOptimizeOption(.{});
    const optimize = .ReleaseFast;
    //const optimize = .Debug;
    const use_tb = true;
    const zig_is_016_or_newer = comptime builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;
    const main_root = if (zig_is_016_or_newer) "src/main.zig" else "src/main_015.zig";
    const bin_converter_root = if (zig_is_016_or_newer) "src/bin_to_binhce.zig" else "src/bin_to_binhce_015.zig";

    const exe = b.addExecutable(.{
        .name = "lambergar",
        .root_module = b.createModule(.{
            .root_source_file = b.path(main_root),
            .target = target,
            .optimize = optimize,
        }),
    });
    const options = b.addOptions();
    options.addOption(bool, "use_tb", use_tb);
    exe.root_module.addOptions("config", options);

    if (use_tb) {
        if (comptime zig_is_016_or_newer) {
            exe.root_module.addCSourceFile(.{
                .file = b.path("src/fathom/tbprobe.c"),
                .flags = &.{"-O3"},
                .language = .c,
            });
            exe.root_module.addCSourceFile(.{
                .file = b.path("src/fathom/tbshim.c"),
                .flags = &.{"-O3"},
                .language = .c,
            });
            exe.root_module.addIncludePath(b.path("src/fathom"));
        } else {
            exe.addCSourceFile(.{
                .file = b.path("src/fathom/tbprobe.c"),
                .flags = &.{"-O3"},
                .language = .c,
            });
            exe.addCSourceFile(.{
                .file = b.path("src/fathom/tbshim.c"),
                .flags = &.{"-O3"},
                .language = .c,
            });
            exe.addIncludePath(b.path("src/fathom"));
        }
    }

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    if (comptime zig_is_016_or_newer) {
        exe.root_module.link_libc = true;
    } else {
        exe.linkLibC();
    }

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(main_root),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Bin to BinHCE converter tool
    const bin_converter = b.addExecutable(.{
        .name = "bin_to_binhce",
        .root_module = b.createModule(.{
            .root_source_file = b.path(bin_converter_root),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    if (comptime zig_is_016_or_newer) {
        bin_converter.root_module.link_libc = true;
    } else {
        bin_converter.linkLibC();
    }
    b.installArtifact(bin_converter);
    const converter_step = b.step("bin-converter", "Build bin40 to binhce converter");
    converter_step.dependOn(&b.addInstallArtifact(bin_converter, .{}).step);
}
