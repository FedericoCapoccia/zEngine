const std = @import("std");

const c = @import("c").c;
const vk = @import("vulkan");

const core = @import("renderer/core.zig");

const VulkanContext = @import("renderer/context.zig").VulkanContext;
const Window = @import("window.zig").Window;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    window: *const Window,
    context: VulkanContext = undefined,

    swapchain: core.swapchain.Swapchain = undefined,

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
        errdefer renderer.context.shutdown();

        renderer.swapchain = core.swapchain.Swapchain{
            .allocator = renderer.allocator,
        };
        renderer.swapchain.init(&renderer.context) catch |err| {
            std.log.err("Failed to create swapchain: {s}", .{@errorName(err)});
            return err;
        };

        errdefer renderer.swapchain.deinit(renderer.context.device);

        // TODO: allocate big image to draw on
    }

    pub fn shutdown(self: *Renderer) void {
        std.log.info("Shutting down renderer", .{});
        self.context.device.deviceWaitIdle() catch {};
        self.swapchain.deinit(self.context.device);
        self.context.shutdown();
    }

    pub fn resize(self: *Renderer) !void {
        std.log.debug("Resizing", .{});
        self.context.device.deviceWaitIdle() catch {};
        self.swapchain.deinit(self.context.device);
        self.swapchain.init(&self.context) catch |err| {
            std.log.err("Failed to recreate swapchain: {s}", .{@errorName(err)});
            return err;
        };
    }
};
