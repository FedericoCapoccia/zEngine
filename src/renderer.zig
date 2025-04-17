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

    swapchain: vk.SwapchainKHR = .null_handle,
    swapchain_extent: vk.Extent2D = undefined,
    swapchain_format: vk.Format = undefined,
    swapchain_images: []vk.Image = undefined,
    swapchain_image_views: []vk.ImageView = undefined,

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

        const win_extent = renderer.window.getSize();
        createSwapchain(renderer, win_extent) catch |err| {
            std.log.err("Failed to create swapchain", .{});
            return err;
        };
        errdefer destroySwapchain(renderer);
        try createImageViews(renderer); // no errdefer because they will be cleaned up with the swapchain

        // TODO: allocate big image to draw on
    }

    pub fn shutdown(self: *const Renderer) void {
        std.log.info("Shutting down renderer", .{});
        self.context.device.deviceWaitIdle() catch {};
        destroySwapchain(self);
        self.context.shutdown();
    }

    pub fn resize(self: *Renderer) !void {
        std.log.debug("Resizing", .{});
        self.context.device.deviceWaitIdle() catch {};

        destroySwapchain(self);
        const win_extent = self.window.getSize();
        try createSwapchain(self, win_extent);
    }
};

// TODO: look at this shit
//
// fn make_swapchain_extent(capabilities: c.VkSurfaceCapabilitiesKHR, opts: SwapchainCreateOpts) c.VkExtent2D {
//     if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
//         return capabilities.currentExtent;
//     }
//
//     var extent = c.VkExtent2D{
//         .width = opts.window_width,
//         .height = opts.window_height,
//     };
//
//     extent.width = @max(
//         capabilities.minImageExtent.width,
//         @min(capabilities.maxImageExtent.width, extent.width));
//     extent.height = @max(
//         capabilities.minImageExtent.height,
//         @min(capabilities.maxImageExtent.height, extent.height));
//
//     return extent;
// }

fn createSwapchain(renderer: *Renderer, window_extent: vk.Extent2D) !void {
    std.log.debug("Creating swapchain", .{});
    const details = renderer.context.surface_details;
    const props = details.caps;

    const image_count = blk: {
        const desired_count = props.min_image_count + 1;
        if (props.max_image_count > 0) {
            break :blk @min(desired_count, props.max_image_count);
        }
        break :blk desired_count;
    };

    const info = vk.SwapchainCreateInfoKHR{
        .surface = renderer.context.surface,
        .min_image_count = image_count,
        .image_format = details.format.format,
        .image_color_space = details.format.color_space,
        .image_extent = window_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = props.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = details.present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = .null_handle,
    };

    renderer.swapchain = try renderer.context.device.createSwapchainKHR(&info, null);
    errdefer renderer.context.device.destroySwapchainKHR(renderer.swapchain, null);
    renderer.swapchain_extent = window_extent;
    renderer.swapchain_format = details.format.format;
    renderer.swapchain_images = try renderer.context.device.getSwapchainImagesAllocKHR(renderer.swapchain, renderer.allocator);
    errdefer renderer.allocator.free(renderer.swapchain_images);
}

fn destroySwapchain(self: *const Renderer) void {
    std.log.debug("Destroying swapchain", .{});
    destroyImageViews(self) catch |err| {
        std.log.warn("Failed to destroy image view: {s}", .{err});
    };
    self.context.device.destroySwapchainKHR(self.swapchain, null);
    self.allocator.free(self.swapchain_images);
}

fn createImageViews(renderer: *Renderer) !void {
    renderer.swapchain_image_views = try renderer.allocator.alloc(vk.ImageView, renderer.swapchain_images.len);
    errdefer renderer.allocator.free(renderer.swapchain_image_views);

    for (renderer.swapchain_images, renderer.swapchain_image_views) |image, *view| {
        const info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = renderer.swapchain_format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        view.* = try renderer.context.device.createImageView(&info, null);
    }
}

fn destroyImageViews(renderer: *const Renderer) !void {
    for (renderer.swapchain_image_views) |view| {
        if (view != .null_handle) {
            renderer.context.device.destroyImageView(view, null);
        }
    }
    renderer.allocator.free(renderer.swapchain_image_views);
}
