const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const fsm_mod = b.addModule("fsm", .{
        .source_file = .{.path = "src/main.zig"},
    });

    const lib = b.addStaticLibrary(.{
        .name = "zigfsm",
        .root_source_file = .{
            .path = "src/main.zig",
        },
        .target = target,
        .optimize = mode,
    });

    b.installArtifact(lib);

    const main_tests = b.addTest(.{ .name = "tests", .root_source_file = .{ .path = "src/main.zig" } });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = .{ .path = "src/benchmark.zig" },
        .optimize = std.builtin.Mode.ReleaseFast,
    });
    benchmark.addModule("fsm", fsm_mod);

    b.installArtifact(benchmark);

    const run_cmd = b.addRunArtifact(benchmark);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("benchmark", "Run the benchmark");
    run_step.dependOn(&run_cmd.step);
}
