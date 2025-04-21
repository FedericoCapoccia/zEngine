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

var resize_requested: bool = false;
fn onResize(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    resize_requested = true;
    _ = window;
    _ = width;
    _ = height;
}

pub const FrameData = struct {
    pool: vk.CommandPool = .null_handle,
    cmd: vk.CommandBuffer = .null_handle,
    image_acquired: vk.Semaphore = .null_handle,
    render_finished_sem: vk.Semaphore = .null_handle,
    render_finished_fen: vk.Fence = .null_handle,

    pub fn init(self: *FrameData, device: vk.DeviceProxy, qfamilies: core.gpu.QueueFamilyBundle) !void {
        const pool_info = vk.CommandPoolCreateInfo{
            .queue_family_index = qfamilies.graphics,
            .flags = .{ .reset_command_buffer_bit = true, .transient_bit = true },
        };
        self.pool = try device.createCommandPool(&pool_info, null);
        errdefer device.destroyCommandPool(self.pool, null);

        const buff_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.pool,
            .command_buffer_count = 1,
            .level = .primary,
        };
        try device.allocateCommandBuffers(&buff_info, @ptrCast(&self.cmd));

        self.image_acquired = try device.createSemaphore(&.{}, null);
        errdefer device.destroySemaphore(self.image_acquired, null);

        self.render_finished_sem = try device.createSemaphore(&.{}, null);
        errdefer device.destroySemaphore(self.render_finished_sem, null);

        const fence_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true },
        };
        self.render_finished_fen = try device.createFence(&fence_info, null);
        errdefer self.device.destroyFence(self.render_finished_fen, null);
    }

    pub fn deinit(self: *FrameData, device: vk.DeviceProxy) void {
        device.deviceWaitIdle() catch {};

        device.destroyCommandPool(self.pool, null);
        device.destroySemaphore(self.image_acquired, null);
        device.destroySemaphore(self.render_finished_sem, null);
        device.destroyFence(self.render_finished_fen, null);

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
    instance: vk.InstanceProxy,
    messenger: ?vk.DebugUtilsMessengerEXT,
    // -- this
    surface: vk.SurfaceKHR,
    // -- core.gpu and this
    pdev: vk.PhysicalDevice,
    qfamilies: core.gpu.QueueFamilyBundle,
    // -- core.device
    device: vk.DeviceProxy,
    queues: core.device.QueueBundle,

    vma: c.VmaAllocator,

    // Rendering infrastructure
    swapchain: core.swapchain.Swapchain,

    draw_image: core.image.AllocatedImage,
    draw_extent: vk.Extent2D,
    scale: f32 = 1.0,

    triangle_pipeline: vk.Pipeline,
    triangle_layout: vk.PipelineLayout,

    frames: [MAX_FRAMES_IN_FLIGHT]FrameData,
    current_frame: u8 = 0,

    imgui_pool: vk.DescriptorPool,

    fn getCurrentFrame(self: *const Renderer) *FrameData {
        return @ptrCast(@constCast(&self.frames[@intCast(self.current_frame % MAX_FRAMES_IN_FLIGHT)]));
    }

    pub fn new(allocator: std.mem.Allocator, window: *const Window) !Renderer {
        std.log.info("Initializing renderer", .{});

        _ = c.glfwSetFramebufferSizeCallback(window.handle, onResize);

        // core Vulkan components initialization
        const instance = core.instance.create(allocator, enable_validation) catch |err| {
            std.log.err("Failed to create Instance: {s}", .{@errorName(err)});
            return error.InstanceCreationFailed;
        };
        var messenger: ?vk.DebugUtilsMessengerEXT = null;
        if (enable_validation) {
            messenger = core.instance.createMessenger(instance) catch |err| {
                std.log.err("Failed to create DebugUtilsMessenger: {s}", .{@errorName(err)});
                return error.DebugUtilsMessengerCreationFailed;
            };
        }
        errdefer core.instance.destroy(instance, messenger, allocator);

        const surface = window.createVulkanSurface(instance) catch |err| {
            std.log.err("Failed to create Surface: {s}", .{@errorName(err)});
            return error.SurfaceCreationFailed;
        };
        errdefer instance.destroySurfaceKHR(surface, null);

        const selection_res = core.gpu.select(instance, surface, allocator) catch |err| {
            std.log.err("Failed to select PhysicalDevice: {s}", .{@errorName(err)});
            return error.PhysicalDeviceSelectionFailed;
        };
        const pdevice = selection_res.device;
        const qfamilies = selection_res.qfamilies;

        const device = core.device.create(instance, pdevice, qfamilies, allocator) catch |err| {
            std.log.err("Failed to create Device: {s}", .{@errorName(err)});
            return error.PhysicalDeviceSelectionFailed;
        };
        errdefer core.device.destroy(device, allocator);
        const queues = core.device.getQueues(device, qfamilies);

        const vma_info = c.VmaAllocatorCreateInfo{
            .vulkanApiVersion = c.VK_API_VERSION_1_4,
            .instance = @ptrFromInt(@intFromEnum(instance.handle)),
            .physicalDevice = @ptrFromInt(@intFromEnum(pdevice)),
            .device = @ptrFromInt(@intFromEnum(device.handle)),
        };

        var vma: c.VmaAllocator = undefined;
        if (c.vmaCreateAllocator(&vma_info, &vma) != c.VK_SUCCESS) {
            std.log.err("Failed to create VulkanMemoryAllocator", .{});
            return error.VmaAllocatorCreationFailed;
        }
        errdefer c.vmaDestroyAllocator(vma);

        // NOTE: Swapchain and rendering infrastructure
        const swapchain_info = core.swapchain.SwapchainInfo{
            .instance = &instance,
            .surface = surface,
            .physical_device = pdevice,
            .device = &device,
            .window = window,
        };

        var swapchain = core.swapchain.Swapchain{};
        try swapchain.create(swapchain_info, allocator);

        const draw_image = try core.image.create(vma, device);
        errdefer {
            device.destroyImageView(draw_image.view, null);
            c.vmaDestroyImage(vma, @ptrFromInt(@intFromEnum(draw_image.image)), draw_image.alloc);
        }

        // NOTE: Pipeline stuff

        const vertex_code align(4) = @embedFile("resources/shaders/triangle.vert.spv").*;
        const fragment_code align(4) = @embedFile("resources/shaders/triangle.frag.spv").*;
        const vert_mod = try create_shader_module(device, &vertex_code);
        const frag_mod = try create_shader_module(device, &fragment_code);
        defer device.destroyShaderModule(vert_mod, null);
        defer device.destroyShaderModule(frag_mod, null);

        const layout_create_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = 0,
            .p_set_layouts = null,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };
        const pip_layout = try device.createPipelineLayout(&layout_create_info, null);

        const pipeline_info = core.pipeline.PipelineBuildInfo{
            .topology = .triangle_list,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_format = .undefined,
            .color_format = draw_image.format,
            .layout = pip_layout,
            .fragment_module = frag_mod,
            .vertex_module = vert_mod,
        };

        const pipeline = try core.pipeline.create_pipeline(device, pipeline_info);
        // TODO: add errdefer for pipeline and layout

        // NOTE: frame stuff
        var frames: [MAX_FRAMES_IN_FLIGHT]FrameData = .{FrameData{}} ** MAX_FRAMES_IN_FLIGHT;

        for (frames, 0..) |_, idx| {
            //self.frames[idx] = FrameData{};
            try frames[idx].init(device, qfamilies);
        }
        errdefer {
            for (frames, 0..) |_, idx| {
                frames[idx].deinit(device);
            }
        }

        const pool_sizes = [_]vk.DescriptorPoolSize{
            vk.DescriptorPoolSize{ .type = .sampler, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .combined_image_sampler, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .sampled_image, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .storage_image, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .uniform_texel_buffer, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .storage_texel_buffer, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .uniform_buffer, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .uniform_buffer_dynamic, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .storage_buffer_dynamic, .descriptor_count = 1000 },
            vk.DescriptorPoolSize{ .type = .input_attachment, .descriptor_count = 1000 },
        };

        const pool_create_info = vk.DescriptorPoolCreateInfo{
            .flags = .{ .free_descriptor_set_bit = true },
            .max_sets = 1000,
            .pool_size_count = @intCast(pool_sizes.len),
            .p_pool_sizes = @ptrCast(&pool_sizes[0]),
        };

        const imgui_pool = try device.createDescriptorPool(&pool_create_info, null);
        _ = c.ImGui_CreateContext(null);
        _ = c.cImGui_ImplGlfw_InitForVulkan(window.handle, true);

        const imgui_pipeline_info = c.VkPipelineRenderingCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = @ptrCast(&draw_image.format),
        };

        const imgui_init_info = c.ImGui_ImplVulkan_InitInfo{
            .Instance = @ptrFromInt(@intFromEnum(instance.handle)),
            .PhysicalDevice = @ptrFromInt(@intFromEnum(pdevice)),
            .Device = @ptrFromInt(@intFromEnum(device.handle)),
            .QueueFamily = qfamilies.graphics,
            .Queue = @ptrFromInt(@intFromEnum(queues.graphics)),
            .DescriptorPool = @ptrFromInt(@intFromEnum(imgui_pool)),
            .MinImageCount = MAX_FRAMES_IN_FLIGHT,
            .ImageCount = MAX_FRAMES_IN_FLIGHT,
            .MSAASamples = c.VK_SAMPLE_COUNT_1_BIT,
            .UseDynamicRendering = true,
            .PipelineRenderingCreateInfo = imgui_pipeline_info,
        };

        _ = c.cImGui_ImplVulkan_Init(@ptrCast(@constCast(&imgui_init_info)));
        _ = c.cImGui_ImplVulkan_CreateFontsTexture();

        return Renderer{
            .allocator = allocator,
            .window = window,
            .instance = instance,
            .messenger = messenger,
            .surface = surface,
            .pdev = pdevice,
            .qfamilies = qfamilies,
            .device = device,
            .queues = queues,
            .vma = vma,
            .swapchain = swapchain,
            .frames = frames,
            .draw_image = draw_image,
            .draw_extent = vk.Extent2D{
                .width = draw_image.extent.width,
                .height = draw_image.extent.height,
            },
            .triangle_pipeline = pipeline,
            .triangle_layout = pip_layout,
            .imgui_pool = imgui_pool,
        };
    }

    pub fn shutdown(self: *Renderer) void {
        self.device.deviceWaitIdle() catch {};

        c.cImGui_ImplVulkan_Shutdown();
        self.device.destroyDescriptorPool(self.imgui_pool, null);

        for (self.frames, 0..) |_, idx| {
            self.frames[idx].deinit(self.device);
        }

        self.device.destroyPipelineLayout(self.triangle_layout, null);
        self.device.destroyPipeline(self.triangle_pipeline, null);

        self.device.destroyImageView(self.draw_image.view, null);
        c.vmaDestroyImage(
            self.vma,
            @ptrFromInt(@intFromEnum(self.draw_image.image)),
            self.draw_image.alloc,
        );

        self.swapchain.cleanup(self.device, self.allocator);

        c.vmaDestroyAllocator(self.vma);
        core.device.destroy(self.device, self.allocator);
        self.instance.destroySurfaceKHR(self.surface, null);
        core.instance.destroy(self.instance, self.messenger, self.allocator);
    }

    pub fn resize(self: *Renderer) !void {
        self.device.deviceWaitIdle() catch {};

        const swapchain_info = core.swapchain.SwapchainInfo{
            .instance = &self.instance,
            .surface = self.surface,
            .physical_device = self.pdev,
            .device = &self.device,
            .window = self.window,
        };

        try self.swapchain.create(swapchain_info, self.allocator);
    }

    pub fn draw(self: *Renderer) !void {
        const width_to_be_scaled: f32 = @floatFromInt(@min(self.swapchain.extent.width, self.draw_image.extent.width));
        const height_to_be_scaled: f32 = @floatFromInt(@min(self.swapchain.extent.height, self.draw_image.extent.height));
        self.draw_extent.width = @intFromFloat(width_to_be_scaled * self.scale);
        self.draw_extent.height = @intFromFloat(height_to_be_scaled * self.scale);

        const frame = self.getCurrentFrame();
        var should_resize = false;

        _ = try self.device.waitForFences(1, @ptrCast(&frame.render_finished_fen), vk.TRUE, std.math.maxInt(u64));

        const acquire_result = self.swapchain.acquireNextImage(self.device, frame.image_acquired, .null_handle) catch |err| {
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
        try self.device.resetFences(1, @ptrCast(&frame.render_finished_fen));

        const image = self.swapchain.images[acquire_result.index];
        try self.device.resetCommandBuffer(frame.cmd, .{});

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        };

        try self.device.beginCommandBuffer(frame.cmd, &begin_info);

        utils.transitionImage(self.device, frame, self.draw_image.image, .undefined, .general, self.qfamilies.graphics);

        clear_background(frame.cmd, self.device, self.draw_image.image);

        utils.transitionImage(self.device, frame, self.draw_image.image, .general, .color_attachment_optimal, self.qfamilies.graphics);

        draw_geometry(frame.cmd, self.device, self.draw_image.view, self.draw_extent, self.triangle_pipeline);

        utils.transitionImage(self.device, frame, self.draw_image.image, .color_attachment_optimal, .transfer_src_optimal, self.qfamilies.graphics);
        utils.transitionImage(self.device, frame, image, .undefined, .transfer_dst_optimal, self.qfamilies.graphics);

        utils.copy_image(self.device, frame.cmd, self.draw_image.image, image, self.draw_extent, self.swapchain.extent);

        utils.transitionImage(self.device, frame, image, .transfer_dst_optimal, .present_src_khr, self.qfamilies.graphics);

        try self.device.endCommandBuffer(frame.cmd);

        const cmd_submit_info = vk.CommandBufferSubmitInfo{
            .command_buffer = frame.cmd,
            .device_mask = 0,
        };

        const wait_info = utils.semaphoreSubmitInfo(.{ .color_attachment_output_bit = true }, frame.image_acquired);
        const sig_info = utils.semaphoreSubmitInfo(.{ .all_graphics_bit = true }, frame.render_finished_sem);
        const submit_info = utils.submitInfo(&cmd_submit_info, &sig_info, &wait_info);

        try self.device.queueSubmit2(self.queues.graphics, 1, @ptrCast(&submit_info), frame.render_finished_fen);

        const present_info = vk.PresentInfoKHR{
            .p_swapchains = @ptrCast(&self.swapchain.handle),
            .swapchain_count = 1,
            .p_wait_semaphores = @ptrCast(&frame.render_finished_sem),
            .wait_semaphore_count = 1,
            .p_image_indices = @ptrCast(&acquire_result.index),
        };

        const res = self.device.queuePresentKHR(self.queues.graphics, &present_info) catch |err| {
            if (err != error.OutOfDateKHR) {
                std.log.err("Failed to present on the queue: {s}", .{@errorName(err)});
                return error.QueuePresentFailed;
            }

            try self.resize();
            self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
            return;
        };

        if (res == vk.Result.suboptimal_khr or should_resize or resize_requested) {
            try self.resize();
            resize_requested = false;
        }

        self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }
};

fn clear_background(cmd: vk.CommandBuffer, device: vk.DeviceProxy, image: vk.Image) void {
    const value = vk.ClearColorValue{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } };
    const range = utils.imageSubresourceRange(.{ .color_bit = true });
    device.cmdClearColorImage(cmd, image, .general, &value, 1, @ptrCast(&range));
}

fn draw_geometry(
    cmd: vk.CommandBuffer,
    device: vk.DeviceProxy,
    view: vk.ImageView,
    extent: vk.Extent2D,
    pipeline: vk.Pipeline,
) void {
    const color_attachment = vk.RenderingAttachmentInfo{
        .image_view = view,
        .image_layout = .color_attachment_optimal,
        .load_op = .load,
        .store_op = .store,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .resolve_image_view = .null_handle,
        .clear_value = vk.ClearValue{
            .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } },
        },
    };

    const rend_info = vk.RenderingInfo{
        .render_area = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layer_count = 1,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment),
        .p_depth_attachment = null,
        .p_stencil_attachment = null,
        .view_mask = 0,
    };

    device.cmdBeginRendering(cmd, &rend_info);

    device.cmdBindPipeline(cmd, .graphics, pipeline);

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    };

    device.cmdSetViewport(cmd, 0, 1, @ptrCast(&viewport));

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = extent.width, .height = extent.height },
    };

    device.cmdSetScissor(cmd, 0, 1, @ptrCast(&scissor));

    device.cmdDraw(cmd, 3, 1, 0, 0);
    // device.cmdBindPipeline(cmd, .graphics, .null_handle);
    c.cImGui_ImplVulkan_RenderDrawData(c.ImGui_GetDrawData(), @ptrFromInt(@intFromEnum(cmd)));

    device.cmdEndRendering(cmd);
}

fn create_shader_module(device: vk.DeviceProxy, code: []const u8) !vk.ShaderModule {
    std.debug.assert(code.len % 4 == 0); // check for alignment

    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = code.len,
        .p_code = @alignCast(@ptrCast(code.ptr)),
    };

    return device.createShaderModule(&create_info, null);
}
