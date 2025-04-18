const vk = @import("vulkan");

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
