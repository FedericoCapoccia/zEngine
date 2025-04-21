const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vulkan");

const c = @import("clibs.zig").c;
const core = @import("renderer/core.zig");

pub extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *c.GLFWwindow, allocation_callbacks: ?*const vk.AllocationCallbacks, surface: *vk.SurfaceKHR) vk.Result;

pub const Window = struct {
    handle: *c.GLFWwindow,

    pub fn init(width: i32, height: i32, title: [*:0]const u8) !Window {
        std.log.info("Initializing window", .{});

        _ = c.glfwInit();

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        c.glfwWindowHint(c.GLFW_VISIBLE, c.GLFW_FALSE);
        const handle = c.glfwCreateWindow(width, height, title, null, null).?;

        _ = c.glfwSetWindowSizeLimits(handle, 200, 200, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);

        if (builtin.target.os.tag == .windows) {
            const native = @cImport({
                @cDefine("GLFW_EXPOSE_NATIVE_WIN32", {});
                @cInclude("GLFW/glfw3.h");
                @cInclude("GLFW/glfw3native.h");
                @cInclude("dwmapi.h");
            });

            const hwnd = native.glfwGetWin32Window(@ptrCast(handle));
            const dark: native.BOOL = native.TRUE;
            _ = native.DwmSetWindowAttribute(hwnd, 20, &dark, 4);
        }

        return Window{ .handle = handle };
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

    pub fn show(self: *const Window) void {
        c.glfwShowWindow(self.handle);
    }

    pub fn hide(self: *const Window) void {
        c.glfwHideWindow(self.handle);
    }

    pub fn pollEvents() void {
        c.glfwPollEvents();
    }

    pub fn shouldClose(self: *const Window) bool {
        return c.glfwWindowShouldClose(self.handle) != 0;
    }

    pub fn setTitle(self: *const Window, title: [*:0]const u8) void {
        c.glfwSetWindowTitle(self.handle, title);
    }

    pub fn createVulkanSurface(self: *const Window, instance: vk.InstanceProxy) !vk.SurfaceKHR {
        var surface: vk.SurfaceKHR = undefined;
        _ = glfwCreateWindowSurface(instance.handle, self.handle, null, &surface);
        return surface;
    }

    pub fn getRequiredVulkanExtensions(allocator: std.mem.Allocator) !std.ArrayList([*:0]const u8) {
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
