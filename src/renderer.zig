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

        // TODO: allocate big image to draw on
    }

    pub fn shutdown(self: *Renderer) void {
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

const SwapchainDetails = struct {
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    caps: vk.SurfaceCapabilitiesKHR,
};

fn querySwapchainDetails(ctx: *VulkanContext) !SwapchainDetails {
    std.log.debug("Querying surface details", .{});
    var details: SwapchainDetails = undefined;

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
    std.log.warn("Current extent: {d}, {d}", .{ details.caps.current_extent.width, details.caps.current_extent.height });
    std.log.warn("min extent: {d}, {d}", .{ details.caps.min_image_extent.width, details.caps.min_image_extent.height });
    std.log.warn("max extent: {d}, {d}", .{ details.caps.max_image_extent.width, details.caps.max_image_extent.height });
    return details;
}

fn createSwapchain(renderer: *Renderer, window_extent: vk.Extent2D) !void {
    std.log.debug("Creating swapchain", .{});
    const details = try querySwapchainDetails(&renderer.context);
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

    renderer.swapchain_image_views = try renderer.allocator.alloc(vk.ImageView, renderer.swapchain_images.len);
    errdefer renderer.allocator.free(renderer.swapchain_image_views);

    for (renderer.swapchain_images, renderer.swapchain_image_views) |image, *view| {
        try createImageView(view, image, renderer.swapchain_format, renderer.context.device);
    }
}

fn destroySwapchain(self: *Renderer) void {
    std.log.debug("Destroying swapchain", .{});

    for (self.swapchain_image_views) |view| {
        self.context.device.destroyImageView(view, null);
    }
    self.allocator.free(self.swapchain_image_views);
    self.swapchain_image_views = undefined;

    self.swapchain_format = undefined;
    self.swapchain_extent = undefined;

    self.context.device.destroySwapchainKHR(self.swapchain, null);
    self.allocator.free(self.swapchain_images);
    self.swapchain_images = undefined;
}

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
