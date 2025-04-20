const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vulkan");

const c = @import("clibs.zig").c;
const core = @import("renderer/core.zig");
const utils = @import("renderer/utils.zig");
const Window = @import("window.zig").Window;

const enable_validation: bool = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

const MAX_FRAMES_IN_FLIGHT = 2;

pub const FrameData = struct {
    device: vk.DeviceProxy = undefined,
    pool: vk.CommandPool = .null_handle,
    cmd: vk.CommandBuffer = .null_handle,
    image_acquired: vk.Semaphore = .null_handle,
    render_finished_sem: vk.Semaphore = .null_handle,
    render_finished_fen: vk.Fence = .null_handle,

    pub fn init(self: *FrameData, renderer: *const Renderer) !void {
        self.device = renderer.device;
        const pool_info = vk.CommandPoolCreateInfo{
            .queue_family_index = renderer.qfamilies.graphics,
            .flags = .{ .reset_command_buffer_bit = true, .transient_bit = true },
        };
        self.pool = try self.device.createCommandPool(&pool_info, null);
        errdefer self.device.destroyCommandPool(self.pool, null);

        const buff_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.pool,
            .command_buffer_count = 1,
            .level = .primary,
        };
        try self.device.allocateCommandBuffers(&buff_info, @ptrCast(&self.cmd));

        self.image_acquired = try self.device.createSemaphore(&.{}, null);
        errdefer self.device.destroySemaphore(self.image_acquired, null);

        self.render_finished_sem = try self.device.createSemaphore(&.{}, null);
        errdefer self.device.destroySemaphore(self.render_finished_sem, null);

        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true },
        };
        self.render_finished_fen = try self.device.createFence(&fence_info, null);
        errdefer self.device.destroyFence(self.render_finished_fen, null);
    }

    pub fn deinit(self: *FrameData) void {
        self.device.deviceWaitIdle() catch {};

        self.device.destroyCommandPool(self.pool, null);
        self.device.destroySemaphore(self.image_acquired, null);
        self.device.destroySemaphore(self.render_finished_sem, null);
        self.device.destroyFence(self.render_finished_fen, null);

        self.pool = .null_handle;
        self.cmd = .null_handle;
        self.image_acquired = .null_handle;
        self.render_finished_sem = .null_handle;
        self.render_finished_fen = .null_handle;
    }
};

pub const Renderer = struct {
    pub const device_extensions = [_][*:0]const u8{
        vk.extensions.khr_swapchain.name,
        vk.extensions.khr_dynamic_rendering.name,
        vk.extensions.khr_synchronization_2.name,
        vk.extensions.khr_timeline_semaphore.name,
    };

    allocator: std.mem.Allocator,
    window: *const Window,

    // Core Vulkan components initialization
    // -- core.instance
    instance: vk.InstanceProxy = undefined,
    messenger: ?vk.DebugUtilsMessengerEXT = null,
    // -- this
    surface: vk.SurfaceKHR = .null_handle,
    // -- core.gpu and this
    pdev: vk.PhysicalDevice = .null_handle,
    qfamilies: core.gpu.QueueFamilyBundle = undefined,
    // -- core.device
    device: vk.DeviceProxy = undefined,
    queues: core.device.QueueBundle = undefined,
    // imgui_pool: vk.DescriptorPool = .null_handle,

    // Rendering infrastructure
    swapchain: core.swapchain.Swapchain = undefined,
    frames: [MAX_FRAMES_IN_FLIGHT]FrameData = undefined,
    current_frame: u8 = 0,

    fn getCurrentFrame(self: *const Renderer) *FrameData {
        return @ptrCast(@constCast(&self.frames[@intCast(self.current_frame % MAX_FRAMES_IN_FLIGHT)]));
    }

    pub fn init(self: *Renderer) !void {
        std.log.info("Initializing renderer", .{});

        // NOTE: core Vulkan components initialization
        core.instance.create(self, enable_validation) catch |err| {
            std.log.err("Failed to create Instance: {s}", .{@errorName(err)});
            return error.InstanceCreationFailed;
        };
        errdefer core.instance.destroy(self);

        self.surface = self.window.createVulkanSurface(self.instance) catch |err| {
            std.log.err("Failed to create Surface: {s}", .{@errorName(err)});
            return error.SurfaceCreationFailed;
        };
        errdefer self.instance.destroySurfaceKHR(self.surface, null);

        core.gpu.select(self) catch |err| {
            std.log.err("Failed to select PhysicalDevice: {s}", .{@errorName(err)});
            return error.PhysicalDeviceSelectionFailed;
        };

        core.device.create(self) catch |err| {
            std.log.err("Failed to create Device: {s}", .{@errorName(err)});
            return error.PhysicalDeviceSelectionFailed;
        };
        errdefer core.device.destroy(self);

        // NOTE: Swapchain and rendering infrastructure
        self.swapchain = core.swapchain.Swapchain{
            .allocator = self.allocator,
            .device = &self.device,
        };
        try self.swapchain.create(self);

        for (self.frames, 0..) |_, idx| {
            self.frames[idx] = FrameData{};
            try self.frames[idx].init(self);
        }
        errdefer {
            for (self.frames, 0..) |_, idx| {
                self.frames[idx].deinit();
            }
        }

        // try init_imgui(self);
    }
    // const vma_info = c.VmaAllocatorCreateInfo{
    //         .vulkanApiVersion = c.VK_API_VERSION_1_4,
    //         .instance = @ptrFromInt(@intFromEnum(context.instance.handle)),
    //         .physicalDevice = @ptrFromInt(@intFromEnum(context.gpu)),
    //         .device = @ptrFromInt(@intFromEnum(context.device.handle)),
    //     };
    //
    //     if (c.vmaCreateAllocator(&vma_info, &context.vma) != c.VK_SUCCESS) {
    //         std.log.err("Failed to create VulkanMemoryAllocator", .{});
    //         return error.VmaAllocatorCreationFailed;
    //     }
    //     errdefer c.vmaDestroyAllocator(context.vma);

    pub fn shutdown(self: *Renderer) void {
        self.device.deviceWaitIdle() catch {};

        for (self.frames, 0..) |_, idx| {
            self.frames[idx].deinit();
        }

        self.swapchain.cleanup();

        // --- Device
        core.device.destroy(self);
        // --- PyDevice
        self.qfamilies = undefined;
        self.pdev = .null_handle;
        // --- Surface
        self.instance.destroySurfaceKHR(self.surface, null);
        self.surface = .null_handle;
        // --- Instance
        core.instance.destroy(self);
    }

    pub fn resize(self: *Renderer) !void {
        self.device.deviceWaitIdle() catch {};
        try self.swapchain.create(self);
    }

    pub fn draw(self: *Renderer) !void {
        const frame = self.getCurrentFrame();
        var should_resize = false;

        _ = try frame.device.waitForFences(1, @ptrCast(&frame.render_finished_fen), vk.TRUE, std.math.maxInt(u64));

        const acquire_result = self.swapchain.acquireNextImage(frame.image_acquired, .null_handle) catch |err| {
            std.log.err("Failed to acquire next image from swapchain: {s}", .{@errorName(err)});
            return error.AcquireNextSwapchainImageFailed;
        };

        switch (acquire_result.result) {
            vk.Result.error_out_of_date_khr => {
                try self.resize();
                return;
            },
            vk.Result.suboptimal_khr => should_resize = true,
            vk.Result.timeout => std.log.warn("vkAcquireNextImageKHR timeout", .{}),
            vk.Result.not_ready => std.log.warn("vkAcquireNextImageKHR not ready", .{}),
            else => {},
        }

        // IMPORTANT to be here see:
        // https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/04_Swap_chain_recreation.html#_fixing_a_deadlock
        try frame.device.resetFences(1, @ptrCast(&frame.render_finished_fen));

        const image = self.swapchain.images[acquire_result.index];
        try frame.device.resetCommandBuffer(frame.cmd, .{});

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        };

        try frame.device.beginCommandBuffer(frame.cmd, &begin_info);

        utils.transitionImage(frame, image, .undefined, .general, self.qfamilies.graphics);

        clear_background(frame.cmd, frame.device, image);

        utils.transitionImage(frame, image, .general, .present_src_khr, self.qfamilies.graphics);

        try frame.device.endCommandBuffer(frame.cmd);

        const cmd_submit_info = vk.CommandBufferSubmitInfo{
            .command_buffer = frame.cmd,
            .device_mask = 0,
        };

        const wait_info = utils.semaphoreSubmitInfo(.{ .color_attachment_output_bit = true }, frame.image_acquired);
        const sig_info = utils.semaphoreSubmitInfo(.{ .all_graphics_bit = true }, frame.render_finished_sem);
        const submit_info = utils.submitInfo(&cmd_submit_info, &sig_info, &wait_info);

        try frame.device.queueSubmit2(self.queues.graphics, 1, @ptrCast(&submit_info), frame.render_finished_fen);

        const present_info = vk.PresentInfoKHR{
            .p_swapchains = @ptrCast(&self.swapchain.handle),
            .swapchain_count = 1,
            .p_wait_semaphores = @ptrCast(&frame.render_finished_sem),
            .wait_semaphore_count = 1,
            .p_image_indices = @ptrCast(&acquire_result.index),
        };

        const res = frame.device.queuePresentKHR(self.queues.graphics, &present_info) catch |err| {
            if (err != error.OutOfDateKHR) {
                std.log.err("Failed to present on the queue: {s}", .{@errorName(err)});
                return error.QueuePresentFailed;
            }

            try self.resize();
            self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
            return;
        };

        if (res == vk.Result.suboptimal_khr or should_resize) {
            try self.resize();
        }

        self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }
};

fn clear_background(cmd: vk.CommandBuffer, device: vk.DeviceProxy, image: vk.Image) void {
    const value = vk.ClearColorValue{ .float_32 = .{ 0.0, 1.0, 1.0, 1.0 } };
    const range = utils.imageSubresourceRange(.{ .color_bit = true });
    device.cmdClearColorImage(cmd, image, .general, &value, 1, @ptrCast(&range));
}

// fn init_imgui(self: *Renderer) !void {
//     const pool_sizes = [_]vk.DescriptorPoolSize{
//         vk.DescriptorPoolSize{ .type = .sampler, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .combined_image_sampler, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .sampled_image, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .storage_image, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .uniform_texel_buffer, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .storage_texel_buffer, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .uniform_buffer, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .uniform_buffer_dynamic, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .storage_buffer_dynamic, .descriptor_count = 1000 },
//         vk.DescriptorPoolSize{ .type = .input_attachment, .descriptor_count = 1000 },
//     };
//
//     const pool_create_info = vk.DescriptorPoolCreateInfo{
//         .flags = .{ .free_descriptor_set_bit = true },
//         .max_sets = 1000,
//         .pool_size_count = @intCast(pool_sizes.len),
//         .p_pool_sizes = @ptrCast(&pool_sizes[0]),
//     };
//
//     self.imgui_pool = try self.device.createDescriptorPool(&pool_create_info, null);
//
//     _ = c.ImGui_CreateContext(null);
//     _ = c.cImGui_ImplGlfw_InitForVulkan(self.window.handle, false);
//
//     const pipeline_info = c.VkPipelineRenderingCreateInfo{
//         .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
//         .pNext = null,
//         .colorAttachmentCount = 1,
//         .pColorAttachmentFormats = @ptrCast(&self.swapchain.format),
//     };
//
//     const init_info = c.ImGui_ImplVulkan_InitInfo{
//         .Instance = @ptrFromInt(@intFromEnum(self.instance.handle)),
//         .PhysicalDevice = @ptrFromInt(@intFromEnum(self.pdev)),
//         .Device = @ptrFromInt(@intFromEnum(self.device.handle)),
//         .QueueFamily = self.qfamilies.graphics,
//         .Queue = @ptrFromInt(@intFromEnum(self.queues.graphics)),
//         .DescriptorPool = @ptrFromInt(@intFromEnum(self.imgui_pool)),
//         .MinImageCount = MAX_FRAMES_IN_FLIGHT,
//         .ImageCount = MAX_FRAMES_IN_FLIGHT,
//         .MSAASamples = c.VK_SAMPLE_COUNT_1_BIT,
//         .UseDynamicRendering = true,
//         .PipelineRenderingCreateInfo = pipeline_info,
//     };
//
//     _ = c.cImGui_ImplVulkan_Init(@ptrCast(@constCast(&init_info)));
//     _ = c.cImGui_ImplVulkan_CreateFontsTexture();
// }
