const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zigfunc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zigfunc tool");
    run_step.dependOn(&run_cmd.step);

    // Unit tests for each module
    const types_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const editor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/editor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_types_tests = b.addRunArtifact(types_tests);
    const run_parser_tests = b.addRunArtifact(parser_tests);
    const run_editor_tests = b.addRunArtifact(editor_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_types_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_editor_tests.step);
}
