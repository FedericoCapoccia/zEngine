const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const env = try std.process.getEnvMap(b.allocator);

    const exe = b.addExecutable(.{
        .name = "zEngine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.linkLibCpp();

    exe.addIncludePath(b.path("thirdparty/VulkanHeaders/include"));
    exe.addIncludePath(b.path("thirdparty/VMA/include"));
    exe.addIncludePath(b.path("thirdparty/GLFW/include"));
    exe.addIncludePath(b.path("thirdparty/imgui"));
    exe.addCSourceFile(.{ .file = b.path("src/renderer/vma.cpp"), .flags = &.{""} });

    const zglfw = b.dependency("zglfw", .{
        .x11 = false,
        .wayland = true,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));

    if (target.result.os.tag != .emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
    }

    const imgui_lib = b.addStaticLibrary(.{
        .name = "cimgui",
        .target = target,
        .optimize = optimize,
    });
    imgui_lib.addIncludePath(b.path("thirdparty/imgui"));
    imgui_lib.addIncludePath(b.path("thirdparty/GLFW/include"));
    imgui_lib.linkLibCpp();
    imgui_lib.addCSourceFiles(.{
        .files = &.{
            "thirdparty/imgui/imgui.cpp",
            "thirdparty/imgui/imgui_demo.cpp",
            "thirdparty/imgui/imgui_draw.cpp",
            "thirdparty/imgui/imgui_tables.cpp",
            "thirdparty/imgui/imgui_widgets.cpp",
            "thirdparty/imgui/imgui_impl_glfw.cpp",
            "thirdparty/imgui/imgui_impl_vulkan.cpp",
            "thirdparty/imgui/dcimgui.cpp",
            "thirdparty/imgui/dcimgui_impl_glfw.cpp",
            "thirdparty/imgui/dcimgui_impl_vulkan.cpp",
            "thirdparty/imgui/dcimgui_internal.cpp",
        },
        .flags = &.{"-DGLFW_INCLUDE_NONE"},
    });
    if (target.result.os.tag == .windows) {
        const vulkan_sdk = env.get("VULKAN_SDK") orelse @panic("Failed to retrieve VULKAN_SDK env var");
        imgui_lib.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{vulkan_sdk}) catch unreachable });
    }

    imgui_lib.addIncludePath(b.path("thirdparty/VulkanHeaders/include"));
    exe.linkLibrary(imgui_lib);

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
