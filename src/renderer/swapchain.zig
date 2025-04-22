const std = @import("std");

const vk = @import("vulkan");
const c = @import("../clibs.zig").c;

const Renderer = @import("../renderer.zig").Renderer;
const Window = @import("../window.zig").Window;

pub const SwapchainInfo = struct {
    instance: *const vk.InstanceProxy,
    surface: vk.SurfaceKHR,
    physical_device: vk.PhysicalDevice,
    device: *const vk.DeviceProxy,
    extent: vk.Extent2D,
};

const Details = struct {
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    capabilities: vk.SurfaceCapabilitiesKHR,

    pub fn query(info: SwapchainInfo, allocator: std.mem.Allocator) !Details {
        const formats = try info.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
            info.physical_device,
            info.surface,
            allocator,
        );
        const present_modes = try info.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
            info.physical_device,
            info.surface,
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

        const capabilities = try info.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(info.physical_device, info.surface);

        return Details{
            .format = format,
            .present_mode = present,
            .capabilities = capabilities,
        };
    }
};

pub const Swapchain = struct {
    handle: vk.SwapchainKHR = .null_handle,
    extent: vk.Extent2D = undefined,
    format: vk.SurfaceFormatKHR = undefined,
    images: []vk.Image = undefined,
    image_views: []vk.ImageView = undefined,

    pub fn create(self: *Swapchain, info: SwapchainInfo, allocator: std.mem.Allocator) !void {
        info.device.deviceWaitIdle() catch {};
        // If the handle is not null it means that we are trying to recreate the swapchain on a resize event or similar
        // In that case we save the old handle, we cleanup the image views, we free the images and image_views containers
        // after that, we reset the internal state of the swapchain and we create a new one,
        // finally after the creation we destroy the old handle
        const old_swapchain: ?vk.SwapchainKHR = if (self.handle != .null_handle) self.handle else null;
        if (old_swapchain) |_| {
            for (self.image_views) |view| {
                info.device.destroyImageView(view, null);
            }
            allocator.free(self.image_views);
            allocator.free(self.images);
            self.image_views = undefined;
            self.images = undefined;
            self.format = undefined;
            self.extent = undefined;
            self.handle = .null_handle;
        }
        defer {
            if (old_swapchain) |old| { // cleanup old swapchain if present
                info.device.destroySwapchainKHR(old, null);
            }
        }

        const details = try Details.query(info, allocator);
        const capabilities = details.capabilities;

        self.extent = choose_extent(info.extent, capabilities);
        self.format = details.format;

        const image_count = blk: {
            const desired_count = capabilities.min_image_count + 1;
            if (capabilities.max_image_count > 0) {
                break :blk @min(desired_count, capabilities.max_image_count);
            }
            break :blk desired_count;
        };

        const create_info = vk.SwapchainCreateInfoKHR{
            .surface = info.surface,
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

        self.handle = try info.device.createSwapchainKHR(&create_info, null);
        errdefer info.device.destroySwapchainKHR(self.handle, null);

        self.images = try info.device.getSwapchainImagesAllocKHR(self.handle, allocator);
        errdefer allocator.free(self.images);

        self.image_views = try allocator.alloc(vk.ImageView, self.images.len);
        errdefer allocator.free(self.image_views);

        for (self.images, self.image_views) |image, *view| {
            try createImageView(view, image, self.format.format, info.device);
        }
    }

    fn choose_extent(current: vk.Extent2D, capabilities: vk.SurfaceCapabilitiesKHR) vk.Extent2D {
        if (capabilities.current_extent.width != std.math.maxInt(u32)) {
            std.log.warn("Porcoddio", .{});
            return capabilities.current_extent;
        }

        var extent = current;

        extent.width = @min(capabilities.max_image_extent.width, @max(capabilities.min_image_extent.width, extent.width));
        extent.height = @min(capabilities.max_image_extent.height, @max(capabilities.min_image_extent.height, extent.height));

        std.log.warn("DIOCANE width :{d}, height: {d}", .{ extent.width, extent.height });
        return extent;
    }

    pub fn cleanup(self: *Swapchain, device: vk.DeviceProxy, allocator: std.mem.Allocator) void {
        for (self.image_views) |view| {
            device.destroyImageView(view, null);
        }
        allocator.free(self.image_views);
        device.destroySwapchainKHR(self.handle, null);
        allocator.free(self.images);

        self.handle = .null_handle;
        self.extent = undefined;
        self.format = undefined;
        self.images = undefined;
        self.image_views = undefined;
    }

    pub fn acquireNextImage(
        self: *Swapchain,
        device: vk.DeviceProxy,
        semaphore: vk.Semaphore,
        fence: vk.Fence,
    ) !AcquireNextImageResult {
        const result = device.acquireNextImageKHR(self.handle, std.math.maxInt(u64), semaphore, fence) catch |err| {
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
