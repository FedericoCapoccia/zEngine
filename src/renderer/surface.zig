const std = @import("std");

const vk = @import("vulkan");

const VulkanContext = @import("context.zig").VulkanContext;

pub fn create(ctx: *VulkanContext) !void {
    std.log.debug("Creating surface", .{});
    ctx.surface = try ctx.window.createVulkanSurface(ctx.instance);
}

pub fn destroy(ctx: *const VulkanContext) void {
    std.log.debug("Destroying surface", .{});
    ctx.instance.destroySurfaceKHR(ctx.surface, null);
}
