//! zigfsm build file
//!
//! Usage:
//!    zig build -Doptimize=ReleaseFast
//!    zig build benchmark
//!    zig build test
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
pub const zigfsm = @import("src/main.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const fsm_mod = b.addModule("zigfsm", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const lib = b.addStaticLibrary(.{
        .name = "zigfsm",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = mode,
    });

    b.installArtifact(lib);

    const main_tests = b.addTest(.{ .name = "tests", .root_source_file = b.path("src/tests.zig") });
    main_tests.root_module.addImport("zigfsm", fsm_mod);

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/benchmark.zig"),
        .optimize = std.builtin.Mode.ReleaseFast,
        .target = target,
    });
    benchmark.root_module.addImport("zigfsm", fsm_mod);

    b.installArtifact(benchmark);

    const run_cmd = b.addRunArtifact(benchmark);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("benchmark", "Run the benchmark");
    run_step.dependOn(&run_cmd.step);
}
