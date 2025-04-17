const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const VulkanContext = @import("context.zig").VulkanContext;

pub const Details = struct {
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    caps: vk.SurfaceCapabilitiesKHR,
};

pub fn create(ctx: *VulkanContext) !void {
    std.log.debug("Creating surface", .{});
    ctx.surface = try ctx.window.createVulkanSurface(ctx.instance);
}

pub fn destroy(ctx: *const VulkanContext) void {
    std.log.debug("Destroying surface", .{});
    ctx.instance.destroySurfaceKHR(ctx.surface, null);
}

pub fn queryDetails(ctx: *VulkanContext) !void {
    std.log.debug("Querying surface details", .{});
    var details: Details = undefined;

    const formats = try ctx.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(ctx.gpu, ctx.surface, ctx.allocator);
    const present_modes = try ctx.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(ctx.gpu, ctx.surface, ctx.allocator);
    defer ctx.allocator.free(formats);
    defer ctx.allocator.free(present_modes);

    details.format = blk: {
        for (formats) |format| {
            if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                break :blk format;
            }
        }
        break :blk formats[0];
    };
    std.log.debug("\tFormat: {s}", .{@tagName(details.format.format)});
    std.log.debug("\tColor space: {s}", .{@tagName(details.format.color_space)});

    details.present_mode = blk: {
        for (present_modes) |pmode| {
            if (pmode == .fifo_relaxed_khr) {
                break :blk pmode;
            }
        }
        break :blk vk.PresentModeKHR.fifo_khr;
    };
    std.log.debug("\tPresent mode: {s}", .{@tagName(details.present_mode)});

    details.caps = try ctx.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.gpu, ctx.surface);
    ctx.surface_details = details;
}
