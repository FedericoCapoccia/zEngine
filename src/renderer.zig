const std = @import("std");

const c = @import("c").c;
const vk = @import("vulkan");

const VulkanContext = @import("renderer/context.zig").VulkanContext;
const core = @import("renderer/core.zig");
const utils = @import("renderer/utils.zig");
const Window = @import("window.zig").Window;

const MAX_FRAMES_IN_FLIGHT = 2;

const FrameData = struct {
    device: vk.DeviceProxy,
    command_pool: vk.CommandPool = .null_handle,
    command_buffer: vk.CommandBuffer = .null_handle,

    pub fn init(frame: *FrameData, ctx: *const VulkanContext) !void {
        frame.device = ctx.device;

        const pool_info = utils.commandPoolCreateInfo(
            ctx.gpu_details.graphics_qfamily,
            .{ .reset_command_buffer_bit = true, .transient_bit = true },
        );

        frame.command_pool = try frame.device.createCommandPool(&pool_info, null);
        errdefer frame.device.destroyCommandPool(frame.command_pool, null);

        const buff_info = utils.commandBufferAllocateInfo(frame.command_pool, 1);
        try frame.device.allocateCommandBuffers(&buff_info, @ptrCast(&frame.command_buffer));
    }

    pub fn reset(frame: *FrameData) void {
        _ = frame;
    }

    pub fn destroy(frame: *FrameData) void {
        frame.device.destroyCommandPool(frame.command_pool, null);
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
        return self._frames[self._frame_counter % MAX_FRAMES_IN_FLIGHT];
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
