const std = @import("std");

const vk = @import("vulkan");
const VulkanContext = @import("context.zig").VulkanContext;

pub const Swapchain = struct {
    allocator: std.mem.Allocator,
    handle: vk.SwapchainKHR = .null_handle,
    extent: vk.Extent2D = undefined,
    format: vk.Format = undefined,
    images: []vk.Image = undefined,
    image_views: []vk.ImageView = undefined,

    pub fn init(swapchain: *Swapchain, ctx: *VulkanContext) !void {
        const details = try querySwapchainDetails(ctx);
        const props = details.capabilities;
        const win_extent = ctx.window.getSize();

        const image_count = blk: {
            const desired_count = props.min_image_count + 1;
            if (props.max_image_count > 0) {
                break :blk @min(desired_count, props.max_image_count);
            }
            break :blk desired_count;
        };

        const info = vk.SwapchainCreateInfoKHR{
            .surface = ctx.surface,
            .min_image_count = image_count,
            .image_format = details.format.format,
            .image_color_space = details.format.color_space,
            .image_extent = win_extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = props.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = details.present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = .null_handle,
        };

        swapchain.handle = try ctx.device.createSwapchainKHR(&info, null);
        errdefer ctx.device.destroySwapchainKHR(swapchain.handle, null);

        swapchain.extent = win_extent;
        swapchain.format = details.format.format;

        swapchain.images = try ctx.device.getSwapchainImagesAllocKHR(swapchain.handle, swapchain.allocator);
        errdefer swapchain.allocator.free(swapchain.images);

        swapchain.image_views = try swapchain.allocator.alloc(vk.ImageView, swapchain.images.len);
        errdefer swapchain.allocator.free(swapchain.image_views);

        for (swapchain.images, swapchain.image_views) |image, *view| {
            try createImageView(view, image, swapchain.format, ctx.device);
        }
    }

    pub fn deinit(self: *Swapchain, device: vk.DeviceProxy) void {
        for (self.image_views) |view| {
            device.destroyImageView(view, null);
        }
        self.allocator.free(self.image_views);
        device.destroySwapchainKHR(self.handle, null);
        self.allocator.free(self.images);

        self.handle = .null_handle;
        self.extent = undefined;
        self.format = undefined;
        self.images = undefined;
        self.image_views = undefined;
    }
};

fn createImageView(view: *vk.ImageView, image: vk.Image, format: vk.Format, device: vk.DeviceProxy) !void {
    const info = vk.ImageViewCreateInfo{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    view.* = try device.createImageView(&info, null);
}

const Details = struct {
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    capabilities: vk.SurfaceCapabilitiesKHR,
};

fn querySwapchainDetails(ctx: *VulkanContext) !Details {
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
    details.present_mode = blk: {
        for (present_modes) |pmode| {
            if (pmode == .fifo_relaxed_khr) {
                break :blk pmode;
            }
        }
        break :blk vk.PresentModeKHR.fifo_khr;
    };
    details.capabilities = try ctx.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.gpu, ctx.surface);
    return details;
}
