const std = @import("std");
const builtin = @import("builtin");

const sdl = @import("zsdl3");
const vk = @import("vulkan");

extern fn SDL_Vulkan_CreateSurface(window: *sdl.Window, instance: vk.Instance, allocator: ?*const vk.AllocationCallbacks, surface: *vk.SurfaceKHR) bool;

pub const Window = struct {
    handle: *sdl.Window,
    title: [*:0]const u8,

    pub fn init(window: *Window, width: i32, height: i32, title: [*:0]const u8) !void {
        std.log.info("Initializing window", .{});
        try sdl.init(.{ .video = true });
        window.title = title;
        window.handle = try sdl.createWindow(title, width, height, .{ .vulkan = true, .resizable = true });
    }

    pub fn shutdown(self: *const Window) void {
        std.log.info("Shutting down window", .{});
        self.handle.destroy();
    }

    pub fn getInstanceProcAddress() vk.PfnGetInstanceProcAddr {
        return @ptrCast(sdl.vk.getVkGetInstanceProcAddr().?);
    }

    pub fn createVulkanSurface(self: *const Window, instance: vk.InstanceProxy) !vk.SurfaceKHR {
        var surface: vk.SurfaceKHR = undefined;

        const res = SDL_Vulkan_CreateSurface(
            self.handle,
            instance.handle,
            null,
            &surface,
        );

        if (!res) {
            return error.FailedToCreateSurface;
        }

        return surface;
    }

    pub fn getRequiredVulkanExtensions(allocator: std.mem.Allocator) !std.ArrayList([*:0]const u8) {
        var count: i32 = undefined;
        const balls = sdl.vk.getInstanceExtensions(&count) orelse return error.SdlError;

        var list = std.ArrayList([*:0]const u8).init(allocator);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try list.append(balls[i]);
        }

        return list;
    }
};
