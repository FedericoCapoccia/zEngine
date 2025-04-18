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
    clibs_mod.addIncludePath(b.path("thirdparty/GLFW/include"));
    clibs_mod.addCSourceFile(.{ .file = b.path("src/renderer/vma.cpp"), .flags = &.{""} });

    const zglfw = b.dependency("zglfw", .{});
    if (target.result.os.tag != .emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
    }

    exe.root_module.addImport("c", clibs_mod);

    //=================================================================================================================
    // Vulkan
    //=================================================================================================================

    switch (target.result.os.tag) {
        .windows => {
            const vulkan_sdk = env.get("VULKAN_SDK") orelse @panic("Failed to retrieve VULKAN_SDK env var");
            exe.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{vulkan_sdk}) catch unreachable });
            exe.linkSystemLibrary("vulkan-1");
            exe.linkSystemLibrary("gdi32");
            exe.linkSystemLibrary("dwmapi");
            exe.linkSystemLibrary("winmm");
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
