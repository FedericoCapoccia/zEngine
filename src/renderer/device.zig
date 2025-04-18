const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const VulkanContext = @import("context.zig").VulkanContext;
const GpuDetails = @import("gpu.zig").Details;

pub fn create(ctx: *VulkanContext) !void {
    std.log.debug("Creating logical device", .{});
    const priorities = [_]f32{1.0};
    const graphics = ctx.gpu_details.graphics_qfamily;
    const compute = ctx.gpu_details.compute_qfamily;
    const transfer = ctx.gpu_details.transfer_qfamility;

    var queue_infos = std.ArrayList(vk.DeviceQueueCreateInfo).init(ctx.allocator);
    defer queue_infos.deinit();

    const graphics_queue_info = vk.DeviceQueueCreateInfo{
        .queue_family_index = graphics,
        .queue_count = 1,
        .p_queue_priorities = &priorities,
    };
    try queue_infos.append(graphics_queue_info);

    if (compute != graphics) {
        const compute_queue_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = compute,
            .queue_count = 1,
            .p_queue_priorities = &priorities,
        };
        try queue_infos.append(compute_queue_info);
    }

    if (transfer != graphics and transfer != compute) {
        const transfer_queue_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = transfer,
            .queue_count = 1,
            .p_queue_priorities = &priorities,
        };
        try queue_infos.append(transfer_queue_info);
    }

    const features = vk.PhysicalDeviceFeatures{};
    const timeline_semaphore_feature = vk.PhysicalDeviceTimelineSemaphoreFeatures{ .timeline_semaphore = 1 };
    const dynamic_rendering_feature = vk.PhysicalDeviceDynamicRenderingFeatures{
        .dynamic_rendering = 1,
        .p_next = @ptrCast(@constCast(&timeline_semaphore_feature)),
    };
    const sync2_feature = vk.PhysicalDeviceSynchronization2Features{
        .synchronization_2 = 1,
        .p_next = @ptrCast(@constCast(&dynamic_rendering_feature)),
    };

    const info = vk.DeviceCreateInfo{
        .p_enabled_features = &features,
        .p_queue_create_infos = queue_infos.items.ptr,
        .queue_create_info_count = @intCast(queue_infos.items.len),
        .pp_enabled_extension_names = &GpuDetails.extensions,
        .enabled_extension_count = @intCast(GpuDetails.extensions.len),
        .p_next = &sync2_feature,
    };

    const handle = try ctx.instance.createDevice(ctx.gpu, &info, null);

    const wrapper = try ctx.allocator.create(vk.DeviceWrapper);
    errdefer ctx._allocator.destroy(wrapper);
    wrapper.* = vk.DeviceWrapper.load(handle, ctx.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);

    ctx.device = vk.DeviceProxy.init(handle, wrapper);
}

pub fn destroy(ctx: *const VulkanContext) void {
    std.log.debug("Destroying logical device", .{});
    ctx.device.destroyDevice(null);
    ctx.allocator.destroy(ctx.device.wrapper);
}
