const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zigfsm",
        .root_source_file = .{
            .path = "src/main.zig",
        },
        .target = target,
        .optimize = mode,
    });

    lib.install();

    const main_tests = b.addTest(.{ .name = "tests", .root_source_file = .{ .path = "src/main.zig" } });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = .{ .path = "src/benchmark.zig" },
        .optimize = std.builtin.Mode.ReleaseFast,
    });

    benchmark.install();

    const run_benchmark_cmd = benchmark.run();
    run_benchmark_cmd.step.dependOn(b.getInstallStep());

    const benchmark_step = b.step("benchmark", "Build library benchmarks");
    benchmark_step.dependOn(&run_benchmark_cmd.step);
}
