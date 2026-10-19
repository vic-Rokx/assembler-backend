//! The fixed build for playground code. Every request gets a copy of this
//! directory with its source written to `src/main.zig`; nothing in a request
//! can change this file or the options it is run with.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });

    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const vapor_dep = b.dependency("vapor", .{
        .target = wasm_target,
        .optimize = optimize,
    });
    const vapor_module = vapor_dep.module("vapor");
    vapor_module.addImport("config", config_module);

    // theme and vapor import each other, a cycle Zig resolves per module.
    const theme_module = b.createModule(.{
        .root_source_file = b.path("src/Theme.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vapor", .module = vapor_module }},
    });
    vapor_module.addImport("theme", theme_module);

    const exe = b.addExecutable(.{
        .name = "playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vapor", .module = vapor_module },
                .{ .name = "theme", .module = theme_module },
                .{ .name = "config", .module = config_module },
            },
        }),
    });
    exe.stack_size = 4 * 1024 * 1024;
    // The JS runtime calls the exported `init`; there is no `main`.
    exe.entry = .disabled;
    exe.rdynamic = true;
    b.installArtifact(exe);
}
