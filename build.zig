const std = @import("std");
const builtin = @import("builtin");

comptime {
    const req_zig = "0.13.0";
    const cur_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(req_zig) catch unreachable;
    if (cur_zig.order(min_zig) == .lt) {
        const error_msg =
            \\Sorry, it looks like your version of zig is too old. :-(
            \\
            \\Nonogram Solver requires the latest build
            \\
            \\{}
            \\
            \\or higher
            \\
            \\Please download the latest build from
            \\https://ziglang.org/download/
            \\
        ;
        @compileError(std.fmt.comptimePrint(error_msg, .{min_zig}));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const lib_nonogram = b.addStaticLibrary(.{
        .name = "nonogram",
        .root_source_file = b.path("src/nonogram.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib_nonogram);

    const lib_serializer = b.addStaticLibrary(.{
        .name = "serializer",
        .root_source_file = b.path("src/serializer.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib_serializer);

    const exe = b.addExecutable(.{
        .name = "nonogram-solver",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_nono_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/nonogram.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_nono_unit_tests = b.addRunArtifact(lib_nono_unit_tests);

    const lib_serial_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/serializer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_serial_unit_tests = b.addRunArtifact(lib_serial_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_nono_unit_tests.step);
    test_step.dependOn(&run_lib_serial_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
