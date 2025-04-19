const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vulkan");
const c = @import("clibs.zig").c;
pub extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *c.GLFWwindow, allocation_callbacks: ?*const vk.AllocationCallbacks, surface: *vk.SurfaceKHR) vk.Result;

const core = @import("renderer/core.zig");

pub const Window = struct {
    handle: *c.GLFWwindow,
    title: [*:0]const u8,

    pub fn init(window: *Window, width: i32, height: i32, title: [*:0]const u8) !void {
        std.log.info("Initializing window", .{});

        _ = c.glfwInit();

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        window.handle = c.glfwCreateWindow(width, height, title, null, null).?;
        window.title = title;

        _ = c.glfwSetWindowSizeLimits(window.handle, 200, 200, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);

        if (builtin.target.os.tag == .windows) {
            const native = @cImport({
                @cDefine("GLFW_EXPOSE_NATIVE_WIN32", {});
                @cInclude("GLFW/glfw3.h");
                @cInclude("GLFW/glfw3native.h");
                @cInclude("dwmapi.h");
            });

            const hwnd = native.glfwGetWin32Window(@ptrCast(window.handle));
            const dark: native.BOOL = native.TRUE;
            _ = native.DwmSetWindowAttribute(hwnd, 20, &dark, 4);
        }
    }

    pub fn shutdown(self: *const Window) void {
        std.log.info("Shutting down window", .{});
        c.glfwDestroyWindow(self.handle);
        c.glfwTerminate();
    }

    pub fn getFramebufferSize(self: *const Window) vk.Extent2D {
        var width: i32 = undefined;
        var height: i32 = undefined;
        c.glfwGetFramebufferSize(self.handle, &width, &height);

        return vk.Extent2D{
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    pub fn createVulkanSurface(self: *const Window, instance: vk.InstanceProxy) !vk.SurfaceKHR {
        var surface: vk.SurfaceKHR = undefined;
        _ = glfwCreateWindowSurface(instance.handle, self.handle, null, &surface);
        return surface;
    }

    pub fn getRequiredVulkanExtensions(self: *const Window, allocator: std.mem.Allocator) !std.ArrayList([*:0]const u8) {
        _ = self;
        var count: u32 = undefined;
        const balls = c.glfwGetRequiredInstanceExtensions(&count);

        var list = std.ArrayList([*:0]const u8).init(allocator);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try list.append(balls[i]);
        }

        return list;
    }
};
