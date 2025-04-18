const std = @import("std");

const c = @import("c").c;
const vk = @import("vulkan");

const VulkanContext = @import("renderer/context.zig").VulkanContext;
const core = @import("renderer/core.zig");
const utils = @import("renderer/utils.zig");
const Window = @import("window.zig").Window;

const MAX_FRAMES_IN_FLIGHT = 2;

pub const FrameData = struct {
    device: vk.DeviceProxy,
    qfamily: u32 = undefined,
    command_pool: vk.CommandPool = .null_handle,
    command_buffer: vk.CommandBuffer = .null_handle,
    swapchain_semaphore: vk.Semaphore = .null_handle,
    render_semaphore: vk.Semaphore = .null_handle,
    render_fence: vk.Fence = .null_handle,

    pub fn init(frame: *FrameData, ctx: *const VulkanContext) !void {
        frame.device = ctx.device;
        frame.qfamily = ctx.gpu_details.graphics_qfamily;

        const pool_info = utils.commandPoolCreateInfo(
            frame.qfamily,
            .{ .reset_command_buffer_bit = true, .transient_bit = true },
        );

        frame.command_pool = try frame.device.createCommandPool(&pool_info, null);
        errdefer frame.device.destroyCommandPool(frame.command_pool, null);

        const buff_info = utils.commandBufferAllocateInfo(frame.command_pool, 1);
        try frame.device.allocateCommandBuffers(&buff_info, @ptrCast(&frame.command_buffer));

        const sem_info = vk.SemaphoreCreateInfo{};
        frame.swapchain_semaphore = try frame.device.createSemaphore(&sem_info, null);
        errdefer frame.device.destroySemaphore(frame.swapchain_semaphore, null);
        frame.render_semaphore = try frame.device.createSemaphore(&sem_info, null);
        errdefer frame.device.destroySemaphore(frame.render_semaphore, null);

        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true },
        };
        frame.render_fence = try frame.device.createFence(&fence_info, null);
        errdefer frame.device.destroyFence(frame.render_fence, null);
    }

    pub fn reset(frame: *FrameData) void {
        _ = frame;
    }

    pub fn destroy(frame: *FrameData) void {
        frame.device.destroyCommandPool(frame.command_pool, null);
        frame.device.destroySemaphore(frame.swapchain_semaphore, null);
        frame.device.destroySemaphore(frame.render_semaphore, null);
        frame.device.destroyFence(frame.render_fence, null);

        frame.device = undefined;
        frame.qfamily = undefined;
        frame.command_pool = .null_handle;
        frame.command_buffer = .null_handle;
        frame.render_semaphore = .null_handle;
        frame.swapchain_semaphore = .null_handle;
        frame.render_fence = .null_handle;
    }
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    window: *const Window,
    context: VulkanContext = undefined,

    swapchain: core.swapchain.Swapchain = undefined,

    graphics_queue: vk.Queue = .null_handle,
    compute_queue: vk.Queue = .null_handle,
    transfer_queue: vk.Queue = .null_handle,

    _frames: [MAX_FRAMES_IN_FLIGHT]FrameData = undefined,
    _frame_counter: u128 = 0,

    pub fn getCurrentFrame(self: *const Renderer) *FrameData {
        return @ptrCast(@constCast(&self._frames[@intCast(self._frame_counter % MAX_FRAMES_IN_FLIGHT)]));
    }

    pub fn init(renderer: *Renderer) !void {
        std.log.info("Initializing renderer", .{});
        renderer.context = VulkanContext{
            .allocator = renderer.allocator,
            .window = renderer.window,
        };
        VulkanContext.init(&renderer.context) catch |err| {
            std.log.err("Failed to initialize VulkanContext: {s}", .{@errorName(err)});
            return err;
        };
        errdefer renderer.context.shutdown();

        renderer.swapchain = core.swapchain.Swapchain{
            .allocator = renderer.allocator,
        };
        renderer.swapchain.init(&renderer.context) catch |err| {
            std.log.err("Failed to create swapchain: {s}", .{@errorName(err)});
            return err;
        };
        errdefer renderer.swapchain.deinit(renderer.context.device);

        renderer.graphics_queue = renderer.context.device.getDeviceQueue(renderer.context.gpu_details.graphics_qfamily, 0);
        renderer.compute_queue = renderer.context.device.getDeviceQueue(renderer.context.gpu_details.compute_qfamily, 0);
        renderer.transfer_queue = renderer.context.device.getDeviceQueue(renderer.context.gpu_details.transfer_qfamility, 0);

        for (renderer._frames, 0..) |_, idx| {
            try renderer._frames[idx].init(&renderer.context);
        }
        errdefer {
            for (renderer._frames, 0..) |_, idx| {
                renderer._frames[idx].destroy();
            }
        }

        // TODO: allocate big image to draw on
    }

    pub fn draw(self: *Renderer) !void {
        const frame = self.getCurrentFrame();

        _ = try frame.device.waitForFences(1, @ptrCast(&frame.render_fence), vk.TRUE, std.math.maxInt(u64));
        try frame.device.resetFences(1, @ptrCast(&frame.render_fence));

        // TODO: acquire next swapchain image index
        const acquire = try frame.device.acquireNextImageKHR(
            self.swapchain.handle,
            std.math.maxInt(u64),
            frame.swapchain_semaphore,
            .null_handle,
        );
        const swapchain_image_index = acquire.image_index;

        if (acquire.result == vk.Result.error_out_of_date_khr) {
            try self.resize();
            return;
        } else if (acquire.result != vk.Result.success and acquire.result != vk.Result.suboptimal_khr) {
            return error.FailedToAcquireSwapchainImage;
        }

        const image = self.swapchain.images[swapchain_image_index];
        const cmd = frame.command_buffer;
        try frame.device.resetCommandBuffer(cmd, .{});

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        };

        try frame.device.beginCommandBuffer(cmd, &begin_info);

        utils.transitionImage(frame, image, .undefined, .general);

        const balls: f32 = @floatFromInt(self._frame_counter);
        const flash = @abs(@sin(balls / 120.0));
        const porcodio: [4]f32 = .{ 0.0, 0.0, flash, 1.0 };
        const clear_value = vk.ClearColorValue{ .float_32 = porcodio };

        const clear_range = utils.imageSubresourceRange(.{ .color_bit = true });

        frame.device.cmdClearColorImage(cmd, image, .general, &clear_value, 1, @ptrCast(&clear_range));

        utils.transitionImage(frame, image, .general, .present_src_khr);

        try frame.device.endCommandBuffer(cmd);

        const cmd_submit_info = vk.CommandBufferSubmitInfo{
            .command_buffer = cmd,
            .device_mask = 0,
        };

        const wait_info = utils.semaphoreSubmitInfo(.{ .color_attachment_output_bit = true }, frame.swapchain_semaphore);
        const sig_info = utils.semaphoreSubmitInfo(.{ .all_graphics_bit = true }, frame.render_semaphore);
        const submit_info = utils.submitInfo(&cmd_submit_info, &sig_info, &wait_info);

        try frame.device.queueSubmit2(self.graphics_queue, 1, @ptrCast(&submit_info), frame.render_fence);

        const present_info = vk.PresentInfoKHR{
            .p_swapchains = @ptrCast(&self.swapchain.handle),
            .swapchain_count = 1,
            .p_wait_semaphores = @ptrCast(&frame.render_semaphore),
            .wait_semaphore_count = 1,
            .p_image_indices = @ptrCast(&swapchain_image_index),
        };

        _ = try frame.device.queuePresentKHR(self.graphics_queue, &present_info);

        self._frame_counter += 1;
    }

    pub fn shutdown(self: *Renderer) void {
        std.log.info("Shutting down renderer", .{});
        self.context.device.deviceWaitIdle() catch {};

        for (self._frames, 0..) |_, idx| {
            self._frames[idx].destroy();
        }

        self.swapchain.deinit(self.context.device);
        self.context.shutdown();
    }

    pub fn resize(self: *Renderer) !void {
        std.log.debug("Resizing", .{});
        self.context.device.deviceWaitIdle() catch {};
        self.swapchain.deinit(self.context.device);
        self.swapchain.init(&self.context) catch |err| {
            std.log.err("Failed to recreate swapchain: {s}", .{@errorName(err)});
            return err;
        };
    }
};
