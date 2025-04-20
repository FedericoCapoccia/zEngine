const std = @import("std");

const vk = @import("vulkan");
const c = @import("../clibs.zig").c;

const Renderer = @import("../renderer.zig").Renderer;

const Details = struct {
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    capabilities: vk.SurfaceCapabilitiesKHR,

    pub fn query(renderer: *const Renderer) !Details {
        const allocator = renderer.allocator;

        const formats = try renderer.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
            renderer.pdev,
            renderer.surface,
            allocator,
        );
        const present_modes = try renderer.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
            renderer.pdev,
            renderer.surface,
            allocator,
        );
        defer allocator.free(formats);
        defer allocator.free(present_modes);

        const format = blk: {
            for (formats) |format| {
                if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                    break :blk format;
                }
            }
            break :blk formats[0];
        };

        const present = blk: {
            for (present_modes) |pmode| {
                if (pmode == .fifo_relaxed_khr) {
                    break :blk pmode;
                }
            }
            break :blk vk.PresentModeKHR.fifo_khr;
        };

        const capabilities = try renderer.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(renderer.pdev, renderer.surface);

        return Details{
            .format = format,
            .present_mode = present,
            .capabilities = capabilities,
        };
    }
};

pub const Swapchain = struct {
    allocator: std.mem.Allocator,
    device: *const vk.DeviceProxy,

    handle: vk.SwapchainKHR = .null_handle,
    extent: vk.Extent2D = undefined,
    format: vk.SurfaceFormatKHR = undefined,
    images: []vk.Image = undefined,
    image_views: []vk.ImageView = undefined,

    pub fn create(self: *Swapchain, renderer: *Renderer) !void {
        self.device.deviceWaitIdle() catch {};
        // If the handle is not null it means that we are trying to recreate the swapchain on a resize event or similar
        // In that case we save the old handle, we cleanup the image views, we free the images and image_views containers
        // after that, we reset the internal state of the swapchain and we create a new one,
        // finally after the creation we destroy the old handle
        const old_swapchain: ?vk.SwapchainKHR = if (self.handle != .null_handle) self.handle else null;
        if (old_swapchain) |_| {
            for (self.image_views) |view| {
                self.device.destroyImageView(view, null);
            }
            self.allocator.free(self.image_views);
            self.allocator.free(self.images);
            self.image_views = undefined;
            self.images = undefined;
            self.format = undefined;
            self.extent = undefined;
            self.handle = .null_handle;
        }
        defer {
            if (old_swapchain) |old| { // cleanup old swapchain if present
                self.device.destroySwapchainKHR(old, null);
            }
        }

        const details = try Details.query(renderer);
        const capabilities = details.capabilities;
        var current_extent = renderer.window.getFramebufferSize();

        while (current_extent.width == 0 or current_extent.height == 0) {
            current_extent = renderer.window.getFramebufferSize();
            c.glfwWaitEvents();
        }

        self.extent = choose_extent(current_extent, capabilities);
        self.format = details.format;

        const image_count = blk: {
            const desired_count = capabilities.min_image_count + 1;
            if (capabilities.max_image_count > 0) {
                break :blk @min(desired_count, capabilities.max_image_count);
            }
            break :blk desired_count;
        };

        const info = vk.SwapchainCreateInfoKHR{
            .surface = renderer.surface,
            .min_image_count = image_count,
            .image_format = self.format.format,
            .image_color_space = self.format.color_space,
            .image_extent = self.extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = details.present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_swapchain orelse .null_handle,
        };

        self.handle = try self.device.createSwapchainKHR(&info, null);
        errdefer self.device.destroySwapchainKHR(self.handle, null);

        self.images = try self.device.getSwapchainImagesAllocKHR(self.handle, self.allocator);
        errdefer self.allocator.free(self.images);

        self.image_views = try self.allocator.alloc(vk.ImageView, self.images.len);
        errdefer self.allocator.free(self.image_views);

        for (self.images, self.image_views) |image, *view| {
            try createImageView(view, image, self.format.format, self.device);
        }
    }

    fn choose_extent(current: vk.Extent2D, capabilities: vk.SurfaceCapabilitiesKHR) vk.Extent2D {
        if (capabilities.current_extent.width != std.math.maxInt(u32)) {
            return capabilities.current_extent;
        }

        var extent = current;

        extent.width = @min(capabilities.max_image_extent.width, @max(capabilities.min_image_extent.width, extent.width));
        extent.height = @min(capabilities.max_image_extent.height, @max(capabilities.min_image_extent.height, extent.height));
        return extent;
    }

    pub fn cleanup(self: *Swapchain) void {
        for (self.image_views) |view| {
            self.device.destroyImageView(view, null);
        }
        self.allocator.free(self.image_views);
        self.device.destroySwapchainKHR(self.handle, null);
        self.allocator.free(self.images);

        self.handle = .null_handle;
        self.extent = undefined;
        self.format = undefined;
        self.images = undefined;
        self.image_views = undefined;
    }

    pub fn acquireNextImage(self: *Swapchain, semaphore: vk.Semaphore, fence: vk.Fence) !AcquireNextImageResult {
        const result = self.device.acquireNextImageKHR(self.handle, std.math.maxInt(u64), semaphore, fence) catch |err| {
            return switch (err) {
                error.OutOfDateKHR => .{
                    .result = vk.Result.error_out_of_date_khr,
                    .index = 0,
                },
                else => err,
            };
        };

        return .{
            .result = result.result,
            .index = result.image_index,
        };
    }
};

pub const AcquireNextImageResult = struct {
    result: vk.Result,
    index: u32,
};

fn createImageView(view: *vk.ImageView, image: vk.Image, format: vk.Format, device: *const vk.DeviceProxy) !void {
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
