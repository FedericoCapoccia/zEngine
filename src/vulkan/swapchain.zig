const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vulkan");

pub const Swapchain = struct {
    device: vk.DeviceProxy,
    handle: vk.SwapchainKHR = .null_handle,
    extent: vk.Extent2D = undefined,
    format: vk.SurfaceFormatKHR = undefined,
    images: []vk.Image = undefined,
    views: []vk.ImageView = undefined,
    min_image_count: u32 = undefined,

    pub const Info = struct {
        instance: *const vk.InstanceProxy,
        surface: vk.SurfaceKHR,
        physical_device: vk.PhysicalDevice,
        extent: vk.Extent2D,
    };

    pub const Image = struct {
        handle: vk.Image,
        index: u32,
        view: vk.ImageView,
        format: vk.Format,
    };

    pub const Acquired = struct {
        pub const Result = enum {
            out_of_date,
            suboptimal,
            not_ready,
            timeout,
            success,
        };

        result: Result,
        image: Swapchain.Image,
    };

    pub fn createOrResize(self: *Swapchain, info: Info, allocator: std.mem.Allocator) !void {
        self.device.deviceWaitIdle() catch {};
        // If the handle is not null it means that we are trying to recreate the swapchain on a resize event or similar
        // In that case we save the old handle, we cleanup the image views, we free the images and image_views containers
        // after that, we reset the internal state of the swapchain and we create a new one,
        // finally after the creation we destroy the old handle
        const old_swapchain: ?vk.SwapchainKHR = if (self.handle != .null_handle) self.handle else null;
        if (old_swapchain) |_| {
            for (self.views) |view| {
                self.device.destroyImageView(view, null);
            }

            allocator.free(self.views);
            allocator.free(self.images);
            self.views = undefined;
            self.images = undefined;
            self.format = undefined;
            self.extent = undefined;
            self.handle = .null_handle;
            self.min_image_count = undefined;
        }
        defer {
            if (old_swapchain) |old| { // cleanup old swapchain if present
                self.device.destroySwapchainKHR(old, null);
            }
        }

        const capabilities = try info.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(info.physical_device, info.surface);
        const pmode = try choosePresentMode(info, allocator);
        self.format = try chooseFormat(info, allocator);
        self.extent = chooseExtent(info.extent, capabilities);

        self.min_image_count = blk: {
            const desired_count = capabilities.min_image_count + 1;
            if (capabilities.max_image_count > 0) {
                break :blk @min(desired_count, capabilities.max_image_count);
            }
            break :blk desired_count;
        };

        const create_info = vk.SwapchainCreateInfoKHR{
            .surface = info.surface,
            .min_image_count = self.min_image_count,
            .image_format = self.format.format,
            .image_color_space = self.format.color_space,
            .image_extent = self.extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = pmode,
            .clipped = vk.TRUE,
            .old_swapchain = old_swapchain orelse .null_handle,
        };

        self.handle = try self.device.createSwapchainKHR(&create_info, null);
        errdefer self.device.destroySwapchainKHR(self.handle, null);

        self.images = try self.device.getSwapchainImagesAllocKHR(self.handle, allocator);
        errdefer allocator.free(self.images);

        self.views = try allocator.alloc(vk.ImageView, self.images.len);
        errdefer allocator.free(self.views);

        for (self.images, self.views) |image, *view| {
            const view_info = vk.ImageViewCreateInfo{
                .image = image,
                .view_type = .@"2d",
                .format = self.format.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            view.* = try self.device.createImageView(&view_info, null);
        }
    }

    pub fn destroy(self: *const Swapchain, allocator: std.mem.Allocator) void {
        for (self.views) |view| {
            self.device.destroyImageView(view, null);
        }
        allocator.free(self.views);
        self.device.destroySwapchainKHR(self.handle, null);
        allocator.free(self.images);
    }

    pub fn acquireNext(self: *const Swapchain, semaphore: vk.Semaphore, fence: vk.Fence) !Acquired {
        const result = self.device.acquireNextImageKHR(self.handle, std.math.maxInt(u64), semaphore, fence) catch |err| {
            return switch (err) {
                error.OutOfDateKHR => Acquired{
                    .result = .out_of_date,
                    .image = undefined,
                },
                else => err,
            };
        };

        const res: Acquired.Result = switch (result.result) {
            vk.Result.suboptimal_khr => .suboptimal,
            vk.Result.timeout => .timeout,
            vk.Result.not_ready => .not_ready,
            vk.Result.success => .success,
            else => unreachable,
        };

        return Acquired{
            .result = res,
            .image = Image{
                .index = result.image_index,
                .format = self.format.format,
                .view = self.views[result.image_index],
                .handle = self.images[result.image_index],
            },
        };
    }
};

fn choosePresentMode(info: Swapchain.Info, allocator: std.mem.Allocator) !vk.PresentModeKHR {
    const modes = try info.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(info.physical_device, info.surface, allocator);
    defer allocator.free(modes);
    for (modes) |mode| {
        if (builtin.target.os.tag == .windows and mode == .immediate_khr) {
            return mode;
        }
        if (builtin.target.os.tag == .linux and mode == .immediate_khr) {
            return mode;
        }
    }
    return vk.PresentModeKHR.fifo_khr;
}

fn chooseFormat(info: Swapchain.Info, allocator: std.mem.Allocator) !vk.SurfaceFormatKHR {
    const formats = try info.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(info.physical_device, info.surface, allocator);
    defer allocator.free(formats);
    for (formats) |format| {
        if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
            return format;
        }
    }
    return formats[0];
}

fn chooseExtent(current: vk.Extent2D, capabilities: vk.SurfaceCapabilitiesKHR) vk.Extent2D {
    if (capabilities.current_extent.width != std.math.maxInt(u32)) {
        return capabilities.current_extent;
    }

    var extent = current;
    extent.width = @min(capabilities.max_image_extent.width, @max(capabilities.min_image_extent.width, extent.width));
    extent.height = @min(capabilities.max_image_extent.height, @max(capabilities.min_image_extent.height, extent.height));
    return extent;
}
