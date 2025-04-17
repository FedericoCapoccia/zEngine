const std = @import("std");

const vk = @import("vulkan");

const VulkanContext = @import("renderer/context.zig").VulkanContext;
const Window = @import("window.zig").Window;
const Dimensions = @import("window.zig").Dimensions;

const log = std.log.scoped(.renderer);

pub const Renderer = struct {
    context: VulkanContext,

    pub fn initialize(allocator: std.mem.Allocator, window: *Window) !Renderer {
        log.info("Initializing renderer", .{});
        var self: Renderer = undefined;
        self.context = try VulkanContext.init(allocator, window);

        return self;
    }

    pub fn shutdown(self: *Renderer) void {
        log.info("Shutting down renderer", .{});
        self.context.shutdown();
    }
};
