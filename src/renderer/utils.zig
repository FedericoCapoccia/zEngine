const vk = @import("vulkan");

const FrameData = @import("../renderer.zig").FrameData;

pub fn commandPoolCreateInfo(queue_family_index: u32, flags: vk.CommandPoolCreateFlags) vk.CommandPoolCreateInfo {
    return vk.CommandPoolCreateInfo{
        .queue_family_index = queue_family_index,
        .flags = flags,
    };
}

pub fn commandBufferAllocateInfo(pool: vk.CommandPool, count: u32) vk.CommandBufferAllocateInfo {
    return vk.CommandBufferAllocateInfo{
        .command_pool = pool,
        .command_buffer_count = count,
        .level = .primary,
    };
}

pub fn imageSubresourceRange(mask: vk.ImageAspectFlags) vk.ImageSubresourceRange {
    return vk.ImageSubresourceRange{
        .aspect_mask = mask,
        .base_mip_level = 0,
        .level_count = vk.REMAINING_MIP_LEVELS,
        .base_array_layer = 0,
        .layer_count = vk.REMAINING_ARRAY_LAYERS,
    };
}

pub fn transitionImage(
    frame: *const FrameData,
    image: vk.Image,
    src: vk.ImageLayout,
    dst: vk.ImageLayout,
) void {
    const aspect_mask: vk.ImageAspectFlags = b: {
        if (dst == .depth_attachment_optimal) {
            break :b vk.ImageAspectFlags{ .depth_bit = true };
        }
        break :b vk.ImageAspectFlags{ .color_bit = true };
    };
    // FIXME: .all_commands is inefficient need to look into
    // https://github.com/KhronosGroup/Vulkan-Docs/wiki/Synchronization-Examples
    const barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
        .old_layout = src,
        .new_layout = dst,
        .subresource_range = imageSubresourceRange(aspect_mask),
        .image = image,
        .src_queue_family_index = frame.queue_family,
        .dst_queue_family_index = frame.queue_family,
    };

    const info = vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(@constCast(&barrier)),
    };
    frame.device.cmdPipelineBarrier2(frame.cmd, &info);
    // FIXME: https://vkguide.dev/docs/new_chapter_1/vulkan_mainloop_code/
    // Once we have the range and the barrier, we pack them into a VkDependencyInfo struct and call VkCmdPipelineBarrier2.
    // It is possible to layout transitions multiple images at once by sending more imageMemoryBarriers
    // into the dependency info, which is likely to improve performance if we are doing transitions or barriers
    // for multiple things at once.
}

pub fn semaphoreSubmitInfo(mask: vk.PipelineStageFlags2, semaphore: vk.Semaphore) vk.SemaphoreSubmitInfo {
    return vk.SemaphoreSubmitInfo{
        .semaphore = semaphore,
        .stage_mask = mask,
        .device_index = 0,
        .value = 1,
    };
}

pub fn submitInfo(
    cmd: *const vk.CommandBufferSubmitInfo,
    signal: ?*const vk.SemaphoreSubmitInfo,
    wait: ?*const vk.SemaphoreSubmitInfo,
) vk.SubmitInfo2 {
    var info: vk.SubmitInfo2 = undefined;
    info.s_type = vk.StructureType.submit_info_2;
    info.p_next = null;
    info.flags = .{};

    if (wait) |wa| {
        info.wait_semaphore_info_count = 1;
        info.p_wait_semaphore_infos = @ptrCast(wa);
    }

    if (signal) |sig| {
        info.signal_semaphore_info_count = 1;
        info.p_signal_semaphore_infos = @ptrCast(sig);
    }

    info.command_buffer_info_count = 1;
    info.p_command_buffer_infos = @ptrCast(cmd);

    return info;
}
