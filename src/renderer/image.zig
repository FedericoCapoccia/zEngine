const std = @import("std");

const vk = @import("vulkan");

const c = @import("../clibs.zig").c;
const Window = @import("../window.zig").Window;

pub const AllocatedImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    format: vk.Format,
    extent: vk.Extent3D,
    alloc: c.VmaAllocation,
};

pub fn create(vma: c.VmaAllocator, device: vk.DeviceProxy) !AllocatedImage {
    const max_monitor_extent = Window.getMaxPrimaryMonitorResolution();
    const extent = c.VkExtent3D{ // basically drawing in 4k and then blitting down to swapchain image size
        .width = max_monitor_extent.width,
        .height = max_monitor_extent.height,
        .depth = 1,
    };
    std.log.info("Drawing on image of size: [{d}x{d}]", .{ extent.width, extent.height });

    const format = c.VK_FORMAT_R16G16B16A16_SFLOAT;

    var usage_flags: c.VkImageUsageFlags = 0;
    usage_flags |= c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    usage_flags |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    usage_flags |= c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    usage_flags |= c.VK_IMAGE_USAGE_STORAGE_BIT;

    const image_info = c.VkImageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = extent,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = usage_flags,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    const alloc_info = c.VmaAllocationCreateInfo{
        .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
        .requiredFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    };

    var image: vk.Image = undefined;
    var image_alloc: c.VmaAllocation = undefined;

    const result = c.vmaCreateImage(vma, &image_info, &alloc_info, @ptrCast(&image), &image_alloc, null);

    if (result != c.VK_SUCCESS) {
        return error.FailedToAllocateDrawImage;
    }

    const view_info = vk.ImageViewCreateInfo{
        .view_type = .@"2d",
        .image = image,
        .format = @enumFromInt(format),
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
            .level_count = 1,
        },
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
    };

    const view = try device.createImageView(&view_info, null);

    return AllocatedImage{
        .image = image,
        .alloc = image_alloc,
        .format = @enumFromInt(format),
        .view = view,
        .extent = .{
            .width = extent.width,
            .height = extent.height,
            .depth = extent.depth,
        },
    };
}
