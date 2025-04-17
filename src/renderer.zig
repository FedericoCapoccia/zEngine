const std = @import("std");

const c = @import("c").c;
const vk = @import("vulkan");

const Dimensions = @import("window.zig").Dimensions;
const VulkanContext = @import("renderer/context.zig").VulkanContext;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.renderer);

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    window: *const Window,
    context: VulkanContext = undefined,

    pub fn init(renderer: *Renderer) !void {
        log.info("Initializing renderer", .{});
        renderer.context = VulkanContext{
            .allocator = renderer.allocator,
            .window = renderer.window,
        };
        VulkanContext.init(&renderer.context) catch |err| {
            std.log.err("Failed to initialize VulkanContext: {s}", .{@errorName(err)});
            return err;
        };
    }

    pub fn shutdown(self: *const Renderer) void {
        log.info("Shutting down renderer", .{});
        self.context.shutdown();
    }
};
