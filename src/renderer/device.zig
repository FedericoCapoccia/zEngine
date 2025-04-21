const std = @import("std");

const vk = @import("vulkan");

const Renderer = @import("../renderer.zig").Renderer;
const QueueFamiliyBundle = @import("gpu.zig").QueueFamilyBundle;

pub const QueueBundle = struct {
    graphics: vk.Queue,
    compute: vk.Queue,
    transfer: vk.Queue,
};

pub fn create(
    instance: vk.InstanceProxy,
    pdev: vk.PhysicalDevice,
    qfamilies: QueueFamiliyBundle,
    allocator: std.mem.Allocator,
) !vk.DeviceProxy {
    std.log.debug("Creating logical device", .{});
    const priorities = [_]f32{1.0};
    const graphics = qfamilies.graphics;
    const compute = qfamilies.compute;
    const transfer = qfamilies.transfer;

    var queue_infos = std.ArrayList(vk.DeviceQueueCreateInfo).init(allocator);
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
        .pp_enabled_extension_names = &Renderer.device_extensions,
        .enabled_extension_count = @intCast(Renderer.device_extensions.len),
        .p_next = &sync2_feature,
    };

    const handle = try instance.createDevice(pdev, &info, null);

    const wrapper = try allocator.create(vk.DeviceWrapper);
    errdefer allocator.destroy(wrapper);
    wrapper.* = vk.DeviceWrapper.load(handle, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);

    return vk.DeviceProxy.init(handle, wrapper);
}

pub fn getQueues(device: vk.DeviceProxy, qfamilies: QueueFamiliyBundle) QueueBundle {
    return QueueBundle{
        .graphics = device.getDeviceQueue(qfamilies.graphics, 0),
        .compute = device.getDeviceQueue(qfamilies.compute, 0),
        .transfer = device.getDeviceQueue(qfamilies.transfer, 0),
    };
}

pub fn destroy(device: vk.DeviceProxy, allocator: std.mem.Allocator) void {
    std.log.debug("Destroying logical device", .{});
    device.destroyDevice(null);
    allocator.destroy(device.wrapper);
}
