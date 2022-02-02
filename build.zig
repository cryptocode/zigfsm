const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zigfsm", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const benchmark = b.addExecutable("benchmark", "src/benchmark.zig");
    const target = b.standardTargetOptions(.{});
    benchmark.setTarget(target);
    benchmark.setBuildMode(std.builtin.Mode.ReleaseFast);
    benchmark.install();

    const run_benchmark_cmd = benchmark.run();
    run_benchmark_cmd.step.dependOn(b.getInstallStep());

    const benchmark_step = b.step("benchmark", "Build library benchmarks");
    benchmark_step.dependOn(&run_benchmark_cmd.step);
}
