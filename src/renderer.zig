const std = @import("std");

const c = @import("c").c;
const vk = @import("vulkan");

const Dimensions = @import("window.zig").Dimensions;
const VulkanContext = @import("renderer/context.zig").VulkanContext;
const Window = @import("window.zig").Window;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    window: *const Window,
    context: VulkanContext = undefined,
    current_extent: vk.Extent2D = undefined,

    pub fn init(renderer: *Renderer) !void {
        std.log.info("Initializing renderer", .{});
        renderer.context = VulkanContext{
            .allocator = renderer.allocator,
            .window = renderer.window,
        };
        VulkanContext.init(&renderer.context) catch |err| {
            std.log.err("Failed to initialize VulkanContext: {s}", .{@errorName(err)});
            return err;
        };

        renderer.current_extent = try renderer.window.getFramebufferSize();
        std.log.debug("width: {d}, height: {d}", .{ renderer.current_extent.width, renderer.current_extent.height });
    }

    pub fn shutdown(self: *const Renderer) void {
        std.log.info("Shutting down renderer", .{});
        self.context.shutdown();
    }
};
