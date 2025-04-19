const std = @import("std");

const vk = @import("vulkan");

const Renderer = @import("../renderer.zig").Renderer;

pub const QueueBundle = struct {
    graphics: vk.Queue,
    compute: vk.Queue,
    transfer: vk.Queue,
};

pub fn create(renderer: *Renderer) !void {
    std.log.debug("Creating logical device", .{});
    const allocator = renderer.allocator;
    const priorities = [_]f32{1.0};
    const graphics = renderer.qfamilies.graphics;
    const compute = renderer.qfamilies.compute;
    const transfer = renderer.qfamilies.transfer;

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

    const handle = try renderer.instance.createDevice(renderer.pdev, &info, null);

    const wrapper = try allocator.create(vk.DeviceWrapper);
    errdefer allocator.destroy(wrapper);
    wrapper.* = vk.DeviceWrapper.load(handle, renderer.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);

    renderer.device = vk.DeviceProxy.init(handle, wrapper);

    renderer.queues = QueueBundle{
        .graphics = renderer.device.getDeviceQueue(renderer.qfamilies.graphics, 0),
        .compute = renderer.device.getDeviceQueue(renderer.qfamilies.compute, 0),
        .transfer = renderer.device.getDeviceQueue(renderer.qfamilies.transfer, 0),
    };
}

pub fn destroy(renderer: *Renderer) void {
    std.log.debug("Destroying logical device", .{});
    renderer.device.destroyDevice(null);
    renderer.allocator.destroy(renderer.device.wrapper);
    renderer.device = undefined;
    renderer.queues = undefined;
}
