const std = @import("std");
const builtin = @import("builtin");

const c = @import("c");
const config = @import("config");
const glfw = @import("zglfw");
const vk = @import("vulkan");

const core = @import("core/core.zig");
const RenderContext = @import("vulkan/context.zig").RenderContext;
const Swapchain = @import("vulkan/swapchain.zig").Swapchain;
const vk_utils = @import("vulkan/utils.zig");

const log = std.log.scoped(.engine);

// ===================================================================
// [SECTION] GLFW callbacks
// ===================================================================
fn onError(_: glfw.ErrorCode, desc: ?[*:0]const u8) callconv(.C) void {
    log.err("GLFW error: {s}", .{desc orelse "missing description"});
}

fn onFramebufferResize(window: *glfw.Window, _: c_int, _: c_int) callconv(.C) void {
    const engine = window.getUserPointer(Engine) orelse {
        log.warn("failed to retrieve glfw user pointer of type Engine, skipping callback", .{});
        return;
    };
    engine.window_resized = true;
}

const AllocatedImage = struct {
    handle: vk.Image,
    view: vk.ImageView,
    max_extent: vk.Extent3D,
    format: vk.Format,
    allocation: c.VmaAllocation,
    old_layout: vk.ImageLayout,
};

const Frame = struct {
    graphics_pool: vk.CommandPool = .null_handle,
    draw_cmd: vk.CommandBuffer = .null_handle,
    image_acquired: vk.Semaphore = .null_handle,
    render_done: vk.Semaphore = .null_handle,
    fence: vk.Fence = .null_handle,
    render_target: AllocatedImage = undefined,
    render_extent: vk.Extent2D = undefined,
};

// ===================================================================
// [SECTION] Engine
// ===================================================================
pub const Engine = struct {
    const MAX_FRAMES_IN_FLIGHT: u32 = 2;

    // engine stuff
    allocator: std.mem.Allocator,
    timer: core.Timer = undefined,
    window: *glfw.Window = undefined,
    window_resized: bool = false,
    rctx: RenderContext = undefined,
    gui: ?core.Gui = null,

    // Frame
    frames: [MAX_FRAMES_IN_FLIGHT]Frame = undefined,
    frames_in_flight: u32 = 2, // change it with ImGui at runtime to enable/disable double buffering
    current_frame: u32 = 0,

    pipeline: vk.Pipeline = .null_handle,
    pipeline_layout: vk.PipelineLayout = .null_handle,

    pub fn init(self: *Engine) !void {
        log.info("Initializing engine", .{});
        self.timer = try core.Timer.new();

        // ===================================================================
        // [SECTION] Window
        // ===================================================================
        _ = glfw.setErrorCallback(onError);

        try glfw.init();
        errdefer glfw.terminate();

        if (!glfw.isVulkanSupported()) {
            log.err("Vulkan is not supported", .{});
            return error.VulkanNotSupported;
        }

        glfw.windowHint(.client_api, .no_api);
        glfw.windowHint(.visible, false);
        glfw.windowHint(.scale_to_monitor, true);

        self.window = try glfw.createWindow(1280, 720, "zEngine", null);
        errdefer self.window.destroy();

        self.window.setSizeLimits(200, 200, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);
        self.window.setUserPointer(@ptrCast(self));
        _ = self.window.setFramebufferSizeCallback(onFramebufferResize);

        if (builtin.target.os.tag == .windows) {
            const dark: c.BOOL = c.TRUE;
            const hwnd = c.glfwGetWin32Window(@ptrCast(self.window));
            _ = c.DwmSetWindowAttribute(hwnd, 20, &dark, 4);
        }

        // ===================================================================
        // [SECTION] Render Context
        // ===================================================================
        self.rctx = RenderContext.new(self.allocator, self.window) catch |err| {
            std.log.err("Failed to create render context: {s}", .{@errorName(err)});
            return error.RenderContextCreationFailed;
        };
        errdefer self.rctx.destroy();

        // ===================================================================
        // [SECTION] ImGui
        // ===================================================================
        if (config.imgui_enabled) {
            const info = core.Gui.CreateInfo{
                .window = self.window,
                .instance = self.rctx.instance.handle,
                .physical_device = self.rctx.physical_device,
                .qfamily = self.rctx.graphics_queue.family,
                .queue = self.rctx.graphics_queue.handle,
                .device = &self.rctx.device,
                .target_format = self.rctx.swapchain.format,
                .min_image_count = self.rctx.swapchain.min_image_count,
                .image_count = @intCast(self.rctx.swapchain.images.len),
            };
            self.gui = try core.Gui.new(info);
        }

        // ===================================================================
        // [SECTION] Rendering Data
        // ===================================================================
        {
            self.frames = .{Frame{}} ** MAX_FRAMES_IN_FLIGHT;

            for (0..MAX_FRAMES_IN_FLIGHT) |idx| {
                self.frames[idx].graphics_pool = try self.rctx.device.createCommandPool(&vk.CommandPoolCreateInfo{
                    .queue_family_index = self.rctx.graphics_queue.family,
                    .flags = .{ .transient_bit = true },
                }, null);

                const alloc = vk.CommandBufferAllocateInfo{
                    .command_buffer_count = 1,
                    .command_pool = self.frames[idx].graphics_pool,
                    .level = .primary,
                };
                try self.rctx.device.allocateCommandBuffers(&alloc, @ptrCast(&self.frames[idx].draw_cmd));

                const fence_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };
                self.frames[idx].image_acquired = try self.rctx.device.createSemaphore(&.{}, null);
                self.frames[idx].render_done = try self.rctx.device.createSemaphore(&.{}, null);
                self.frames[idx].fence = try self.rctx.device.createFence(&fence_info, null);
            }

            try vk_utils.nameObject(&self.rctx.device, .semaphore, @intFromEnum(self.frames[0].image_acquired), "ImageAcquired[0]");
            try vk_utils.nameObject(&self.rctx.device, .semaphore, @intFromEnum(self.frames[0].render_done), "RenderDone[0]");
            try vk_utils.nameObject(&self.rctx.device, .fence, @intFromEnum(self.frames[0].fence), "CmdFence[0]");

            try vk_utils.nameObject(&self.rctx.device, .semaphore, @intFromEnum(self.frames[1].image_acquired), "ImageAcquired[1]");
            try vk_utils.nameObject(&self.rctx.device, .semaphore, @intFromEnum(self.frames[1].render_done), "RenderDone[1]");
            try vk_utils.nameObject(&self.rctx.device, .fence, @intFromEnum(self.frames[1].fence), "CmdFence[1]");
        }

        // ===================================================================
        // [SECTION] Render Target
        // ===================================================================
        {
            const monitor_capabilities = try glfw.getVideoMode(glfw.getPrimaryMonitor().?);
            const monitor_extent = vk.Extent3D{
                .depth = 1,
                .width = @intCast(monitor_capabilities.width),
                .height = @intCast(monitor_capabilities.height),
            };
            log.debug("Creating draw image with size [{d}x{d}]", .{ monitor_extent.width, monitor_extent.height });
            const format = vk.Format.r32g32b32a32_sfloat;

            for (0..MAX_FRAMES_IN_FLIGHT) |idx| {
                const image_info = vk.ImageCreateInfo{
                    .image_type = .@"2d",
                    .format = format,
                    .extent = monitor_extent,
                    .mip_levels = 1,
                    .array_layers = 1,
                    .samples = .{ .@"1_bit" = true },
                    .tiling = .optimal,
                    .usage = .{
                        .transfer_src_bit = true,
                        .color_attachment_bit = true,
                    },
                    .sharing_mode = .exclusive,
                    .initial_layout = .undefined,
                };

                const alloc_info = c.VmaAllocationCreateInfo{
                    .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
                    .requiredFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                };

                var image: vk.Image = undefined;
                var image_alloc: c.VmaAllocation = undefined;
                const result = c.vmaCreateImage(
                    self.rctx.vma,
                    @ptrCast(&image_info),
                    &alloc_info,
                    @ptrCast(&image),
                    &image_alloc,
                    null,
                );

                if (result != c.VK_SUCCESS) {
                    return error.FailedToAllocRenderTarget;
                }

                const view_info = vk.ImageViewCreateInfo{
                    .view_type = .@"2d",
                    .image = image,
                    .format = format,
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

                const view = try self.rctx.device.createImageView(&view_info, null);

                self.frames[idx].render_target = AllocatedImage{
                    .handle = image,
                    .view = view,
                    .max_extent = monitor_extent,
                    .format = format,
                    .allocation = image_alloc,
                    .old_layout = .undefined,
                };

                self.frames[idx].render_extent = vk.Extent2D{
                    .width = @min(self.rctx.swapchain.extent.width, self.frames[idx].render_target.max_extent.width),
                    .height = @min(self.rctx.swapchain.extent.height, self.frames[idx].render_target.max_extent.height),
                };
            }
        }

        // ===================================================================
        // [SECTION] Pipeline Creation
        // ===================================================================
        {
            // ===================================================================
            // [SECTION] Shaders Module Creation
            // ===================================================================
            // FIXME: add compilation as compiler step
            const vertex_code align(4) = @embedFile("resources/shaders/triangle.vert.spv").*;
            const fragment_code align(4) = @embedFile("resources/shaders/triangle.frag.spv").*;
            const vert_mod = try vk_utils.createShaderModule(self.rctx.device, &vertex_code);
            const frag_mod = try vk_utils.createShaderModule(self.rctx.device, &fragment_code);
            defer self.rctx.device.destroyShaderModule(vert_mod, null);
            defer self.rctx.device.destroyShaderModule(frag_mod, null);

            // ===================================================================
            // [SECTION] Pipeline Layout
            // ===================================================================
            const layout_create_info = vk.PipelineLayoutCreateInfo{
                .set_layout_count = 0,
                .p_set_layouts = null,
                .push_constant_range_count = 0,
                .p_push_constant_ranges = null,
            };
            self.pipeline_layout = try self.rctx.device.createPipelineLayout(&layout_create_info, null);

            // ===================================================================
            // [SECTION] Pipeline
            // ===================================================================

            // Disabling color blending
            const color_blend_attch = vk.PipelineColorBlendAttachmentState{
                .blend_enable = vk.FALSE,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
                .dst_alpha_blend_factor = .zero,
                .src_alpha_blend_factor = .zero,
                .dst_color_blend_factor = .zero,
                .src_color_blend_factor = .zero,
                .color_blend_op = .add,
                .alpha_blend_op = .add,
            };

            const shader_stages: [2]vk.PipelineShaderStageCreateInfo = .{
                vk.PipelineShaderStageCreateInfo{
                    .module = vert_mod,
                    .stage = .{ .vertex_bit = true },
                    .p_name = "main",
                },
                vk.PipelineShaderStageCreateInfo{
                    .module = frag_mod,
                    .stage = .{ .fragment_bit = true },
                    .p_name = "main",
                },
            };

            const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
                .topology = .triangle_list,
                .primitive_restart_enable = vk.FALSE,
            };

            const rasterizer = vk.PipelineRasterizationStateCreateInfo{
                .polygon_mode = .fill,
                .line_width = 1.0,
                .cull_mode = .{ .back_bit = true },
                .front_face = .clockwise,
                .depth_clamp_enable = vk.FALSE,
                .rasterizer_discard_enable = vk.FALSE,
                .depth_bias_clamp = 0.0,
                .depth_bias_constant_factor = 0.0,
                .depth_bias_enable = vk.FALSE,
                .depth_bias_slope_factor = 0.0,
            };

            // disable multisampling
            const multisampling = vk.PipelineMultisampleStateCreateInfo{
                .sample_shading_enable = vk.FALSE,
                .rasterization_samples = .{ .@"1_bit" = true },
                .min_sample_shading = 1.0,
                .p_sample_mask = null,
                .alpha_to_coverage_enable = vk.FALSE,
                .alpha_to_one_enable = vk.FALSE,
            };

            // disable depth test
            const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
                .depth_test_enable = vk.FALSE,
                .depth_write_enable = vk.FALSE,
                .depth_compare_op = .never,
                .depth_bounds_test_enable = vk.FALSE,
                .stencil_test_enable = vk.FALSE,
                .min_depth_bounds = 0.0,
                .max_depth_bounds = 1.0,
                .front = .{
                    .write_mask = 0,
                    .depth_fail_op = .zero,
                    .compare_mask = 0,
                    .compare_op = .never,
                    .fail_op = .zero,
                    .pass_op = .zero,
                    .reference = 0,
                },
                .back = .{
                    .write_mask = 0,
                    .depth_fail_op = .zero,
                    .compare_mask = 0,
                    .compare_op = .never,
                    .fail_op = .zero,
                    .pass_op = .zero,
                    .reference = 0,
                },
            };

            const render_info = vk.PipelineRenderingCreateInfo{
                .color_attachment_count = 1,
                .p_color_attachment_formats = @ptrCast(&self.frames[0].render_target.format),
                .depth_attachment_format = .undefined,
                .stencil_attachment_format = .undefined,
                .view_mask = 0,
            };

            const viewport_state = vk.PipelineViewportStateCreateInfo{
                .viewport_count = 1,
                .scissor_count = 1,
            };

            const color_blend_info = vk.PipelineColorBlendStateCreateInfo{
                .logic_op_enable = vk.FALSE,
                .logic_op = .copy,
                .attachment_count = 1,
                .p_attachments = @ptrCast(&color_blend_attch),
                .blend_constants = .{ 0, 0, 0, 0 },
            };

            const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{};

            const states: [2]vk.DynamicState = .{
                .viewport,
                .scissor,
            };

            const dynamic_info = vk.PipelineDynamicStateCreateInfo{
                .dynamic_state_count = 2,
                .p_dynamic_states = @ptrCast(&states),
            };

            const pipeline_info = vk.GraphicsPipelineCreateInfo{
                .stage_count = 2,
                .p_stages = @ptrCast(&shader_stages),
                .p_vertex_input_state = &vertex_input_info,
                .p_input_assembly_state = &input_assembly,
                .p_viewport_state = &viewport_state,
                .p_rasterization_state = &rasterizer,
                .p_multisample_state = &multisampling,
                .p_color_blend_state = &color_blend_info,
                .p_depth_stencil_state = &depth_stencil,
                .p_dynamic_state = &dynamic_info,
                .layout = self.pipeline_layout,
                .p_next = &render_info,
                .subpass = 0,
                .base_pipeline_index = 0,
            };

            _ = try self.rctx.device.createGraphicsPipelines(.null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&self.pipeline));
        }
    }

    pub fn shutdown(self: *Engine) void {
        std.log.info("Shutting down engine", .{});
        self.rctx.device.deviceWaitIdle() catch {};

        if (self.gui) |gui| {
            gui.destroy();
        }

        self.rctx.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.rctx.device.destroyPipeline(self.pipeline, null);

        for (0..MAX_FRAMES_IN_FLIGHT) |idx| {
            const frame: *Frame = &self.frames[idx];
            self.rctx.device.destroySemaphore(frame.image_acquired, null);
            self.rctx.device.destroySemaphore(frame.render_done, null);
            self.rctx.device.destroyFence(frame.fence, null);
            self.rctx.device.destroyCommandPool(frame.graphics_pool, null);

            self.rctx.device.destroyImageView(frame.render_target.view, null);
            c.vmaDestroyImage(self.rctx.vma, @ptrFromInt(@intFromEnum(frame.render_target.handle)), frame.render_target.allocation);
        }

        self.rctx.destroy();
        self.window.destroy();
        glfw.terminate();
    }

    pub fn run(self: *Engine) !void {
        std.log.info("Running...", .{});
        self.window.show();

        while (!self.window.shouldClose()) {
            // Update logic
            _ = self.timer.trackUpdate();

            // Render logic
            self.draw() catch |err| {
                log.warn("Failed to draw frame: {s}", .{@errorName(err)});
            };

            _ = self.timer.trackDraw();
            self.timer.computeFrametime();

            glfw.pollEvents();
        }
    }

    fn resize(self: *Engine) !void {
        self.rctx.device.deviceWaitIdle() catch {};
        var width, var height = self.window.getFramebufferSize();
        while (width == 0 or height == 0) {
            glfw.waitEvents();
            width, height = self.window.getFramebufferSize();
        }

        const info = Swapchain.Info{
            .instance = &self.rctx.instance,
            .surface = self.rctx.surface,
            .physical_device = self.rctx.physical_device,
            .extent = vk.Extent2D{ .width = @intCast(width), .height = @intCast(height) },
        };

        try self.rctx.swapchain.createOrResize(info, self.allocator);

        if (self.gui) |gui| {
            gui.onResize(self.rctx.swapchain.min_image_count);
        }

        self.window_resized = false;
        self.timer.frame_counter = 0; // resets frametime tracking on resize
    }

    fn draw(self: *Engine) !void {
        const device: *const vk.DeviceProxy = &self.rctx.device;
        const swapchain: *Swapchain = &self.rctx.swapchain;
        const frame: *Frame = &self.frames[self.current_frame % self.frames_in_flight];

        _ = try device.waitForFences(1, @ptrCast(&frame.fence), vk.TRUE, std.math.maxInt(u64));

        const acquired = try swapchain.acquireNext(frame.image_acquired, .null_handle);

        if (acquired.result == .out_of_date) {
            try self.resize();
            return;
        }

        switch (acquired.result) {
            Swapchain.Acquired.Result.suboptimal => self.window_resized = true,
            Swapchain.Acquired.Result.timeout => log.warn("vkAcquireNextImageKHR timeout", .{}),
            Swapchain.Acquired.Result.not_ready => log.warn("vkAcquireNextImageKHR not ready", .{}),
            Swapchain.Acquired.Result.success => {},
            else => unreachable,
        }

        try device.resetFences(1, @ptrCast(&frame.fence));

        try device.resetCommandPool(frame.graphics_pool, .{});

        const begin_info = vk.CommandBufferBeginInfo{ .flags = .{ .one_time_submit_bit = true } };
        try device.beginCommandBuffer(frame.draw_cmd, &begin_info);

        if (frame.render_target.old_layout == .undefined) { // NOTE: so this is the first time the frame get rolled
            vk_utils.beginLabel(device, frame.draw_cmd, "render_target->color_layout(first time)", .{ 1.0, 0.0, 0.0, 1.0 });
            const barrier = vk_utils.layoutTransition(
                frame.render_target.handle,
                .undefined,
                .color_attachment_optimal,
                .{},
                .{ .color_attachment_write_bit = true },
                .{},
                .{ .color_attachment_output_bit = true },
            );
            device.cmdPipelineBarrier2(
                frame.draw_cmd,
                &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = &.{barrier} },
            );
            vk_utils.endLabel(device, frame.draw_cmd);
        }

        // ===================================================================
        // [SECTION] Geometry
        // ===================================================================
        {
            frame.render_extent.width = @min(swapchain.extent.width, frame.render_target.max_extent.width);
            frame.render_extent.height = @min(swapchain.extent.height, frame.render_target.max_extent.height);

            const color_attachment = vk.RenderingAttachmentInfo{
                .image_view = frame.render_target.view,
                .image_layout = .color_attachment_optimal,
                .load_op = .clear,
                .store_op = .store,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .resolve_image_view = .null_handle,
                .clear_value = vk.ClearValue{
                    .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } },
                },
            };

            const rend_info = vk.RenderingInfo{
                .render_area = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = frame.render_extent },
                .layer_count = 1,
                .color_attachment_count = 1,
                .p_color_attachments = @ptrCast(&color_attachment),
                .p_depth_attachment = null,
                .p_stencil_attachment = null,
                .view_mask = 0,
            };

            device.cmdBeginRendering(frame.draw_cmd, &rend_info);
            vk_utils.beginLabel(&self.rctx.device, frame.draw_cmd, "Triangle", .{ 1.0, 0, 0, 1.0 });

            device.cmdBindPipeline(frame.draw_cmd, .graphics, self.pipeline);
            const viewport = vk.Viewport{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(frame.render_extent.width),
                .height = @floatFromInt(frame.render_extent.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            };

            device.cmdSetViewport(frame.draw_cmd, 0, 1, @ptrCast(&viewport));

            const scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = frame.render_extent,
            };

            device.cmdSetScissor(frame.draw_cmd, 0, 1, @ptrCast(&scissor));

            device.cmdDraw(frame.draw_cmd, 3, 1, 0, 0);

            vk_utils.endLabel(&self.rctx.device, frame.draw_cmd);
            device.cmdEndRendering(frame.draw_cmd);
        }

        {
            vk_utils.beginLabel(device, frame.draw_cmd, "render_target->transfer_src", .{ 1.0, 0.0, 0.0, 1.0 });
            const barrier = vk_utils.layoutTransition(
                frame.render_target.handle,
                .color_attachment_optimal,
                .transfer_src_optimal,
                .{ .color_attachment_write_bit = true },
                .{ .transfer_read_bit = true },
                .{ .color_attachment_output_bit = true },
                .{ .all_transfer_bit = true },
            );
            device.cmdPipelineBarrier2(
                frame.draw_cmd,
                &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = &.{barrier} },
            );
            vk_utils.endLabel(device, frame.draw_cmd);
        }

        {
            vk_utils.beginLabel(device, frame.draw_cmd, "swapchain_image->transfer_dst", .{ 1.0, 0.0, 0.0, 1.0 });
            const barrier = vk_utils.layoutTransition(
                acquired.image.handle,
                .undefined,
                .transfer_dst_optimal,
                .{},
                .{ .transfer_write_bit = true },
                .{ .all_transfer_bit = true }, // This creates a dependency chain at transfer stage so it waits for image_acquired semaphore
                .{ .all_transfer_bit = true },
            );
            device.cmdPipelineBarrier2(
                frame.draw_cmd,
                &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = &.{barrier} },
            );
            vk_utils.endLabel(device, frame.draw_cmd);
        }

        // ===================================================================
        // [SECTION] Blit Image
        // ===================================================================
        {
            vk_utils.beginLabel(device, frame.draw_cmd, "blit render_target->swapchain_image", .{ 1.0, 0.0, 0.0, 1.0 });
            const src_offset_1 = vk.Offset3D{ .x = 0, .y = 0, .z = 0 };
            const src_offset_2 = vk.Offset3D{
                .x = @intCast(frame.render_extent.width),
                .y = @intCast(frame.render_extent.height),
                .z = 1,
            };

            const dst_offset_1 = vk.Offset3D{ .x = 0, .y = 0, .z = 0 };
            const dst_offset_2 = vk.Offset3D{
                .x = @intCast(swapchain.extent.width),
                .y = @intCast(swapchain.extent.height),
                .z = 1,
            };

            const region = vk.ImageBlit2{
                .src_offsets = .{ src_offset_1, src_offset_2 },
                .dst_offsets = .{ dst_offset_1, dst_offset_2 },
                .src_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .dst_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };

            const info = vk.BlitImageInfo2{
                .src_image = frame.render_target.handle,
                .src_image_layout = .transfer_src_optimal,
                .dst_image = acquired.image.handle,
                .dst_image_layout = .transfer_dst_optimal,
                .filter = .linear,
                .region_count = 1,
                .p_regions = @ptrCast(&region),
            };

            device.cmdBlitImage2(frame.draw_cmd, &info);
            vk_utils.endLabel(device, frame.draw_cmd);
        }

        {
            vk_utils.beginLabel(device, frame.draw_cmd, "render_target->color_attachment", .{ 1.0, 0.0, 0.0, 1.0 });
            const barrier = vk_utils.layoutTransition(
                frame.render_target.handle,
                .transfer_src_optimal,
                .color_attachment_optimal,
                .{ .transfer_read_bit = true },
                .{ .color_attachment_write_bit = true },
                .{ .all_transfer_bit = true },
                .{ .color_attachment_output_bit = true },
            );
            device.cmdPipelineBarrier2(
                frame.draw_cmd,
                &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = &.{barrier} },
            );

            frame.render_target.old_layout = .color_attachment_optimal;
            vk_utils.endLabel(device, frame.draw_cmd);
        }

        // ===================================================================
        // [SECTION] GUI
        // ===================================================================
        if (self.gui) |gui| {
            {
                vk_utils.beginLabel(device, frame.draw_cmd, "swapchain->color", .{ 1.0, 0.0, 0.0, 1.0 });
                const barrier = vk_utils.layoutTransition(
                    acquired.image.handle,
                    .transfer_dst_optimal,
                    .color_attachment_optimal,
                    .{ .transfer_write_bit = true },
                    .{ .color_attachment_write_bit = true, .color_attachment_read_bit = true }, // because of load_op
                    .{ .all_transfer_bit = true },
                    .{ .color_attachment_output_bit = true },
                );
                device.cmdPipelineBarrier2(
                    frame.draw_cmd,
                    &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = &.{barrier} },
                );
                vk_utils.endLabel(device, frame.draw_cmd);
            }

            // ===================================================================
            // [SECTION] GUI Pass
            // ===================================================================
            const color_attachment = vk.RenderingAttachmentInfo{
                .image_view = acquired.image.view,
                .image_layout = .color_attachment_optimal,
                .load_op = .load,
                .store_op = .store,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .resolve_image_view = .null_handle,
                .clear_value = vk.ClearValue{
                    .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 0.0 } },
                },
            };

            const rend_info = vk.RenderingInfo{
                .render_area = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent },
                .layer_count = 1,
                .color_attachment_count = 1,
                .p_color_attachments = @ptrCast(&color_attachment),
                .p_depth_attachment = null,
                .p_stencil_attachment = null,
                .view_mask = 0,
            };

            device.cmdBeginRendering(frame.draw_cmd, &rend_info);
            vk_utils.beginLabel(device, frame.draw_cmd, "ImGUI", .{ 0, 1.0, 1.0, 1.0 });

            c.cImGui_ImplVulkan_NewFrame();
            c.cImGui_ImplGlfw_NewFrame();
            c.ImGui_NewFrame();

            // c.ImGui_ShowDemoWindow(null);
            _ = c.ImGui_Begin("Tool", null, 0);
            c.ImGui_Text("Frame time: %.3f ms", self.timer.getFrametimeInMs());
            c.ImGui_Text("FPS: %d", self.timer.getFPS());
            _ = c.ImGui_SliderInt("Frame Buffering", @ptrCast(&self.frames_in_flight), 1, MAX_FRAMES_IN_FLIGHT);
            c.ImGui_Text("Current value: %d", self.frames_in_flight);
            c.ImGui_End();

            c.ImGui_Render();

            gui.draw(frame.draw_cmd);

            vk_utils.endLabel(device, frame.draw_cmd);
            device.cmdEndRendering(frame.draw_cmd);

            {
                vk_utils.beginLabel(device, frame.draw_cmd, "swapchain->present", .{ 1.0, 0.0, 0.0, 1.0 });
                const barrier = vk_utils.layoutTransition(
                    acquired.image.handle,
                    .color_attachment_optimal,
                    .present_src_khr,
                    .{ .color_attachment_write_bit = true },
                    .{},
                    .{ .color_attachment_output_bit = true },
                    .{ .color_attachment_output_bit = true },
                );
                device.cmdPipelineBarrier2(
                    frame.draw_cmd,
                    &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = &.{barrier} },
                );
                vk_utils.endLabel(device, frame.draw_cmd);
            }
        } else {
            // NOTE: if not rendering UI barrier transfer->present
            vk_utils.beginLabel(device, frame.draw_cmd, "swapchain_image->present_khr(no gui)", .{ 1.0, 0.0, 0.0, 1.0 });
            const barrier = vk_utils.layoutTransition(
                acquired.image.handle,
                .transfer_dst_optimal,
                .present_src_khr,
                .{ .transfer_write_bit = true },
                .{},
                .{ .all_transfer_bit = true },
                .{ .color_attachment_output_bit = true },
            );
            device.cmdPipelineBarrier2(
                frame.draw_cmd,
                &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = &.{barrier} },
            );
            vk_utils.endLabel(device, frame.draw_cmd);
        }

        try device.endCommandBuffer(frame.draw_cmd);

        // ===================================================================
        // [SECTION] Submit Command Buffer
        // ===================================================================
        {
            const command_buffer_submit = vk.CommandBufferSubmitInfo{
                .command_buffer = frame.draw_cmd,
                .device_mask = 0,
            };

            const wait_for_swapchain_image_acquired = vk.SemaphoreSubmitInfo{
                .semaphore = frame.image_acquired,
                .stage_mask = .{ .all_transfer_bit = true },
                .value = 0,
                .device_index = 0,
            };

            const signal_on_rendering_done = vk.SemaphoreSubmitInfo{
                .semaphore = frame.render_done,
                .stage_mask = .{ .bottom_of_pipe_bit = true },
                .value = 0,
                .device_index = 0,
            };

            const submit = vk.SubmitInfo2{
                .command_buffer_info_count = 1,
                .p_command_buffer_infos = @ptrCast(&command_buffer_submit),
                .wait_semaphore_info_count = 1,
                .p_wait_semaphore_infos = &.{wait_for_swapchain_image_acquired},
                .signal_semaphore_info_count = 1,
                .p_signal_semaphore_infos = &.{signal_on_rendering_done},
            };

            try device.queueSubmit2(self.rctx.graphics_queue.handle, 1, @ptrCast(&submit), frame.fence);
        }

        // ===================================================================
        // [SECTION] Present
        // ===================================================================
        {
            const info = vk.PresentInfoKHR{
                .swapchain_count = 1,
                .p_swapchains = @ptrCast(&self.rctx.swapchain.handle),
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast(&frame.render_done),
                .p_image_indices = @ptrCast(&acquired.image.index),
            };

            const res = device.queuePresentKHR(self.rctx.graphics_queue.handle, &info) catch |err| {
                if (err != error.OutOfDateKHR) {
                    std.log.err("Failed to present on the queue: {s}", .{@errorName(err)});
                    return error.QueuePresentFailed;
                }

                try self.resize();
                return;
            };

            if (res == vk.Result.suboptimal_khr or self.window_resized) {
                try self.resize();
            }
        }

        self.current_frame = (self.current_frame + 1) % self.frames_in_flight;
    }
};
