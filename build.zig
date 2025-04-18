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

    clibs_mod.addIncludePath(b.path("thirdparty/GLFW/include"));
    clibs_mod.addIncludePath(b.path("thirdparty/wl"));

    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("gdi32");
        exe.linkSystemLibrary("dwmapi");
        exe.linkSystemLibrary("winmm");

        clibs_mod.addCSourceFiles(.{
            .files = &[_][]const u8{
                // common
                "thirdparty/GLFW/src/context.c",
                "thirdparty/GLFW/src/init.c",
                "thirdparty/GLFW/src/input.c",
                "thirdparty/GLFW/src/monitor.c",
                "thirdparty/GLFW/src/platform.c",
                "thirdparty/GLFW/src/vulkan.c",
                "thirdparty/GLFW/src/window.c",
                "thirdparty/GLFW/src/egl_context.c",
                "thirdparty/GLFW/src/osmesa_context.c",
                "thirdparty/GLFW/src/null_init.c",
                "thirdparty/GLFW/src/null_monitor.c",
                "thirdparty/GLFW/src/null_window.c",
                "thirdparty/GLFW/src/null_joystick.c",

                "thirdparty/GLFW/src/win32_module.c",
                "thirdparty/GLFW/src/win32_time.c",
                "thirdparty/GLFW/src/win32_thread.c",

                "thirdparty/GLFW/src/win32_init.c",
                "thirdparty/GLFW/src/win32_joystick.c",
                "thirdparty/GLFW/src/win32_monitor.c",
                "thirdparty/GLFW/src/win32_window.c",
                "thirdparty/GLFW/src/wgl_context.c",
            },
            .flags = &[_][]const u8{
                "-D_GLFW_WIN32",
            },
        });
    } else if (target.result.os.tag == .linux) {
        clibs_mod.addCSourceFiles(.{
            .files = &[_][]const u8{
                // common
                "thirdparty/GLFW/src/context.c",
                "thirdparty/GLFW/src/init.c",
                "thirdparty/GLFW/src/input.c",
                "thirdparty/GLFW/src/monitor.c",
                "thirdparty/GLFW/src/platform.c",
                "thirdparty/GLFW/src/vulkan.c",
                "thirdparty/GLFW/src/window.c",
                "thirdparty/GLFW/src/egl_context.c",
                "thirdparty/GLFW/src/osmesa_context.c",
                "thirdparty/GLFW/src/null_init.c",
                "thirdparty/GLFW/src/null_monitor.c",
                "thirdparty/GLFW/src/null_window.c",
                "thirdparty/GLFW/src/null_joystick.c",

                "thirdparty/GLFW/src/posix_module.c",
                "thirdparty/GLFW/src/posix_time.c",
                "thirdparty/GLFW/src/posix_thread.c",
                "thirdparty/GLFW/src/linux_joystick.c",
                "thirdparty/GLFW/src/posix_poll.c",

                "thirdparty/GLFW/src/wl_init.c",
                "thirdparty/GLFW/src/wl_monitor.c",
                "thirdparty/GLFW/src/wl_window.c",

                "thirdparty/GLFW/src/wgl_context.c",
            },
            .flags = &[_][]const u8{
                "-D_GLFW_WAYLAND",
            },
        });
    } else {
        @panic("Unsupported OS");
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
