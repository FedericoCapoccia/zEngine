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

    // ===================================================================
    // [SECTION] GLFW Zig Bindings
    // ===================================================================
    const zglfw = b.dependency("zglfw", .{
        .x11 = false,
        .wayland = true,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    // ===================================================================
    // [SECTION] Vulkan
    // ===================================================================
    {
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
    }

    // ===================================================================
    // [SECTION] ImGui
    // ===================================================================
    {
        const imgui = b.addLibrary(.{
            .name = "imgui",
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
            }),
        });
        imgui.addIncludePath(b.path("thirdparty/imgui"));
        imgui.addIncludePath(zglfw.artifact("glfw").getEmittedIncludeTree());
        imgui.addIncludePath(b.path("thirdparty/VulkanHeaders/include"));
        imgui.addCSourceFiles(.{
            .files = &.{
                "thirdparty/imgui/imgui.cpp",
                "thirdparty/imgui/imgui_draw.cpp",
                "thirdparty/imgui/imgui_widgets.cpp",
                "thirdparty/imgui/imgui_tables.cpp",
                "thirdparty/imgui/imgui_demo.cpp",
                "thirdparty/imgui/imgui_impl_glfw.cpp",
                "thirdparty/imgui/imgui_impl_vulkan.cpp",
            },
            .flags = &.{"-DGLFW_INCLUDE_NONE"},
        });
        if (target.result.os.tag == .windows) {
            const vulkan_sdk = env.get("VULKAN_SDK") orelse @panic("Failed to retrieve VULKAN_SDK env var");
            imgui.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{vulkan_sdk}) catch unreachable });
        }
        exe.linkLibrary(imgui);
    }

    // ===================================================================
    // [SECTION] VulkanMemoryAllocator
    // ===================================================================
    {
        const vma = b.addLibrary(.{
            .name = "VulkanMemoryAllocator",
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
            }),
        });
        vma.addIncludePath(b.path("thirdparty/VMA/include"));
        vma.addIncludePath(b.path("thirdparty/VulkanHeaders/include"));
        vma.addCSourceFile(.{
            .file = b.addWriteFiles().add("vk_mem_alloc.cpp",
                \\#include <vk_mem_alloc.h>
            ),
            .flags = &.{"-DVMA_IMPLEMENTATION"},
        });
        b.installArtifact(vma);
        exe.linkLibrary(vma);
    }

    // ===================================================================
    // [SECTION] C module
    // ===================================================================
    {
        const files = blk: {
            if (target.result.os.tag == .linux) {
                break :blk b.addWriteFiles().add("c.h",
                    \\#define GLFW_INCLUDE_NONE
                    \\#include <GLFW/glfw3.h>
                    \\#include <vulkan/vulkan.h>
                    \\#include <vk_mem_alloc.h>
                    \\#include <dcimgui.h>
                    \\#include <dcimgui_impl_glfw.h>
                    \\#include <dcimgui_impl_vulkan.h>
                );
            }

            if (target.result.os.tag == .windows) {
                break :blk b.addWriteFiles().add("c.h",
                    \\#define GLFW_INCLUDE_NONE
                    \\#define GLFW_EXPOSE_NATIVE_WIN32
                    \\#include <GLFW/glfw3.h>
                    \\#include <GLFW/glfw3native.h>
                    \\#include <dwmapi.h>
                    \\#include <vulkan/vulkan.h>
                    \\#include <vk_mem_alloc.h>
                    \\#include <dcimgui.h>
                    \\#include <dcimgui_impl_glfw.h>
                    \\#include <dcimgui_impl_vulkan.h>
                );
            }

            @panic("OS not supported");
        };

        const c_translate = b.addTranslateC(.{
            .root_source_file = files,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        c_translate.addIncludePath(zglfw.artifact("glfw").getEmittedIncludeTree());
        c_translate.addIncludePath(b.path("thirdparty/VMA/include"));
        c_translate.addIncludePath(b.path("thirdparty/VulkanHeaders/include"));
        c_translate.addIncludePath(b.path("thirdparty/imgui"));
        exe.root_module.addImport("c", c_translate.createModule());
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
