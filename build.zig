const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const env = try std.process.getEnvMap(b.allocator);

    const exe = b.addExecutable(.{
        .name = "SimpleEngine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.linkLibCpp();

    const clibs_mod = b.addModule("clibs", .{
        .root_source_file = .{ .cwd_relative = "src/clibs.zig" },
    });
    clibs_mod.addIncludePath(b.path("thirdparty/VulkanHeaders/include"));
    clibs_mod.addIncludePath(b.path("thirdparty/VMA/include"));
    clibs_mod.addCSourceFile(.{ .file = b.path("src/renderer/vma.cpp"), .flags = &.{""} });
    exe.root_module.addImport("c", clibs_mod);

    const zsdl = b.dependency("zsdl", .{});
    exe.root_module.addImport("zsdl3", zsdl.module("zsdl3"));

    if (target.result.os.tag == .windows) {
        const sdl_dep = b.dependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .preferred_linkage = .static,
            .lto = optimize != .Debug,
        });
        const sdl_lib = sdl_dep.artifact("SDL3");
        exe.linkLibrary(sdl_lib);
    } else {
        @import("zsdl").link_SDL3(exe);
    }

    //=================================================================================================================
    // Vulkan
    //=================================================================================================================

    switch (target.result.os.tag) {
        .windows => {
            const vulkan_sdk = env.get("VULKAN_SDK") orelse @panic("Failed to retrieve VULKAN_SDK env var");
            exe.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{vulkan_sdk}) catch unreachable });
            exe.linkSystemLibrary("vulkan-1");
        },
        .linux => exe.linkSystemLibrary("vulkan"),
        else => @panic("Unsupported OS"),
    }

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.path("thirdparty/VulkanHeaders/registry/vk.xml"),
    }).module("vulkan-zig");
    exe.root_module.addImport("vulkan", vulkan);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
