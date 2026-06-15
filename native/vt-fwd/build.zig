const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "vibetunnel-fwd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const options = b.addOptions();
    const version = b.option([]const u8, "version", "VibeTunnel version") orelse "unknown";
    options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addOptions("build_options", options);

    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run vt-fwd tests");
    test_step.dependOn(&run_tests.step);

    const run_e2e = b.addSystemCommand(&.{"python3"});
    run_e2e.addFileArg(b.path("test/e2e.py"));
    run_e2e.addArtifactArg(exe);
    const e2e_step = b.step("e2e", "Run vt-fwd end-to-end tests");
    e2e_step.dependOn(&run_e2e.step);
}
