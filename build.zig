const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const reverb = b.dependency("reverb", .{
        .target = target,
        .optimize = optimize,
    });

    const claude = b.dependency("claude", .{
        .target = target,
        .optimize = optimize,
    });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "reverb", .module = reverb.module("reverb") },
        .{ .name = "claude", .module = claude.module("claude") },
        .{ .name = "vertex", .module = claude.module("vertex") },
    };

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });

    const exe = b.addExecutable(.{
        .name = "assembler-backend",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the backend");
    run_step.dependOn(&run_cmd.step);

    // The build tests compile real playground code against the template.
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "playground_template", b.pathFromRoot("playground_template"));
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (imports) |import| test_mod.addImport(import.name, import.module);
    test_mod.addImport("test_options", test_options.createModule());
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    // The template and the zig toolchain are inputs the cache cannot see.
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);
}
