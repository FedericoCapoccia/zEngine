const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("zglfw");
const vk = @import("vulkan");
const vk_utils = @import("vulkan/utils.zig");

const c = @import("c");
const RenderContext = @import("vulkan/context.zig").RenderContext;
const Swapchain = @import("vulkan/swapchain.zig").Swapchain;
const core = @import("core/core.zig");

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

// ===================================================================
// [SECTION] Engine
// ===================================================================
pub const Engine = struct {
    // engine stuff
    allocator: std.mem.Allocator,
    timer: core.Timer = undefined,
    window: *glfw.Window = undefined,
    window_resized: bool = false,
    rctx: RenderContext = undefined,

    // Frame
    graphics_pool: vk.CommandPool = .null_handle,
    draw_cmd: vk.CommandBuffer = .null_handle,
    image_acquired: vk.Semaphore = .null_handle,
    render_done: vk.Semaphore = .null_handle,
    fence: vk.Fence = .null_handle,

    pipeline: vk.Pipeline = .null_handle,
    pipeline_layout: vk.PipelineLayout = .null_handle,

    imgui_pool: vk.DescriptorPool = .null_handle,
    imgui_ctx: *c.ImGuiContext = undefined,

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
        // [SECTION] Rendering Data
        // ===================================================================
        {
            self.graphics_pool = try self.rctx.device.createCommandPool(&vk.CommandPoolCreateInfo{
                .queue_family_index = self.rctx.graphics_queue.family,
                .flags = .{ .transient_bit = true, .reset_command_buffer_bit = true },
            }, null);

            const alloc = vk.CommandBufferAllocateInfo{
                .command_buffer_count = 1,
                .command_pool = self.graphics_pool,
                .level = .primary,
            };
            try self.rctx.device.allocateCommandBuffers(&alloc, @ptrCast(&self.draw_cmd));

            const fence_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };
            self.image_acquired = try self.rctx.device.createSemaphore(&.{}, null);
            self.render_done = try self.rctx.device.createSemaphore(&.{}, null);
            self.fence = try self.rctx.device.createFence(&fence_info, null);
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
                .p_color_attachment_formats = @ptrCast(&self.rctx.swapchain.format),
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

        // ===================================================================
        // [SECTION] ImGui setup
        // ===================================================================
        {
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

            self.imgui_pool = try self.rctx.device.createDescriptorPool(&pool_create_info, null);
            self.imgui_ctx = c.ImGui_CreateContext(null).?;

            const io = c.ImGui_GetIO();
            io.*.ConfigFlags |= c.ImGuiConfigFlags_DpiEnableScaleFonts;
            io.*.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable;

            var font_cfg = c.ImFontConfig{
                .FontDataOwnedByAtlas = false,
                .GlyphMaxAdvanceX = std.math.floatMax(f32),
                .RasterizerMultiply = 1.0,
                .RasterizerDensity = 1.0,
                .OversampleH = 2,
                .OversampleV = 2,
            };

            const font = @embedFile("resources/jetbrainsmono.ttf");

            _ = c.ImFontAtlas_AddFontFromMemoryTTF(
                io.*.Fonts,
                @constCast(font),
                font.len,
                20.0,
                &font_cfg,
                null,
            );

            const scale_x, const scale_y = self.window.getContentScale();

            const style = c.ImGui_GetStyle();
            c.ImGui_StyleColorsDark(style);
            c.ImGuiStyle_ScaleAllSizes(style, @max(scale_x, scale_y));

            style.*.WindowRounding = 0.0;
            style.*.Colors[c.ImGuiCol_WindowBg].w = 1.0;

            for (0..c.ImGuiCol_COUNT) |idx| {
                const col = &style.*.Colors[idx];
                col.*.x = vk_utils.linearizeColorComponent(col.*.x);
                col.*.y = vk_utils.linearizeColorComponent(col.*.y);
                col.*.z = vk_utils.linearizeColorComponent(col.*.z);
            }

            _ = c.cImGui_ImplGlfw_InitForVulkan(@ptrCast(self.window), true);

            const imgui_pipeline_info = c.VkPipelineRenderingCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
                .pNext = null,
                .colorAttachmentCount = 1,
                .pColorAttachmentFormats = @ptrCast(&self.rctx.swapchain.format),
            };

            const imgui_init_info = c.ImGui_ImplVulkan_InitInfo{
                .Instance = @ptrFromInt(@intFromEnum(self.rctx.instance.handle)),
                .PhysicalDevice = @ptrFromInt(@intFromEnum(self.rctx.physical_device)),
                .Device = @ptrFromInt(@intFromEnum(self.rctx.device.handle)),
                .QueueFamily = self.rctx.graphics_queue.family,
                .Queue = @ptrFromInt(@intFromEnum(self.rctx.graphics_queue.handle)),
                .DescriptorPool = @ptrFromInt(@intFromEnum(self.imgui_pool)),
                .MinImageCount = 2,
                .ImageCount = @intCast(self.rctx.swapchain.images.len),
                .MSAASamples = c.VK_SAMPLE_COUNT_1_BIT,
                .UseDynamicRendering = true,
                .PipelineRenderingCreateInfo = imgui_pipeline_info,
            };

            _ = c.cImGui_ImplVulkan_Init(@ptrCast(@constCast(&imgui_init_info)));
            _ = c.cImGui_ImplVulkan_CreateFontsTexture();
        }
    }

    pub fn shutdown(self: *Engine) void {
        std.log.info("Shutting down engine", .{});
        self.rctx.device.deviceWaitIdle() catch {};

        c.cImGui_ImplVulkan_Shutdown();
        self.rctx.device.destroyDescriptorPool(self.imgui_pool, null);
        c.cImGui_ImplGlfw_Shutdown();
        c.ImGui_DestroyContext(self.imgui_ctx);

        self.rctx.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.rctx.device.destroyPipeline(self.pipeline, null);

        self.rctx.device.destroySemaphore(self.image_acquired, null);
        self.rctx.device.destroySemaphore(self.render_done, null);
        self.rctx.device.destroyFence(self.fence, null);
        self.rctx.device.destroyCommandPool(self.graphics_pool, null);

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
        self.window_resized = false;
        self.timer.frame_counter = 0; // resets frametime tracking on resize
    }

    fn draw(self: *Engine) !void {
        const device: *const vk.DeviceProxy = &self.rctx.device;
        const swapchain: *Swapchain = &self.rctx.swapchain;

        _ = try device.waitForFences(1, @ptrCast(&self.fence), vk.TRUE, std.math.maxInt(u64));

        const acquired = try swapchain.acquireNext(self.image_acquired, .null_handle);

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

        try device.resetFences(1, @ptrCast(&self.fence));

        try device.resetCommandBuffer(self.draw_cmd, .{});
        const begin_info = vk.CommandBufferBeginInfo{ .flags = .{ .one_time_submit_bit = true } };
        try device.beginCommandBuffer(self.draw_cmd, &begin_info);

        {
            const to_color = vk.ImageMemoryBarrier2{
                .image = acquired.image.handle,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .old_layout = .undefined,
                .new_layout = .color_attachment_optimal,
                .src_access_mask = .{},
                .dst_access_mask = .{ .color_attachment_write_bit = true },
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },

                .subresource_range = vk.ImageSubresourceRange{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = vk.REMAINING_MIP_LEVELS,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            };

            const info = vk.DependencyInfo{
                .image_memory_barrier_count = 1,
                .p_image_memory_barriers = @ptrCast(@constCast(&to_color)),
            };
            device.cmdPipelineBarrier2(self.draw_cmd, &info);
        }

        c.cImGui_ImplVulkan_NewFrame();
        c.cImGui_ImplGlfw_NewFrame();
        c.ImGui_NewFrame();

        const draw_extent = swapchain.extent;

        const color_attachment = vk.RenderingAttachmentInfo{
            .image_view = acquired.image.view,
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
            .render_area = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = draw_extent },
            .layer_count = 1,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment),
            .p_depth_attachment = null,
            .p_stencil_attachment = null,
            .view_mask = 0,
        };

        device.cmdBeginRendering(self.draw_cmd, &rend_info);

        { // draw geometry

            device.cmdBindPipeline(self.draw_cmd, .graphics, self.pipeline);
            const viewport = vk.Viewport{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(draw_extent.width),
                .height = @floatFromInt(draw_extent.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            };

            device.cmdSetViewport(self.draw_cmd, 0, 1, @ptrCast(&viewport));

            const scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = draw_extent.width, .height = draw_extent.height },
            };

            device.cmdSetScissor(self.draw_cmd, 0, 1, @ptrCast(&scissor));

            device.cmdDraw(self.draw_cmd, 3, 1, 0, 0);
        }

        { // Draw ImGui stuff

            c.ImGui_ShowDemoWindow(null);
            _ = c.ImGui_Begin("Tool", null, 0);
            c.ImGui_Text("Frame time: %.3f ms", self.timer.getFrametimeInMs());
            c.ImGui_Text("FPS: %d", self.timer.getFPS());
            c.ImGui_End();

            c.ImGui_Render();
            const data = c.ImGui_GetDrawData();
            c.cImGui_ImplVulkan_RenderDrawData(data, @ptrFromInt(@intFromEnum(self.draw_cmd)));
        }

        device.cmdEndRendering(self.draw_cmd);

        {
            const to_present = vk.ImageMemoryBarrier2{
                .image = acquired.image.handle,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .old_layout = .color_attachment_optimal,
                .new_layout = .present_src_khr,
                .src_access_mask = .{ .color_attachment_write_bit = true, .color_attachment_read_bit = true },
                .dst_access_mask = .{},
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_stage_mask = .{ .bottom_of_pipe_bit = true },

                .subresource_range = vk.ImageSubresourceRange{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = vk.REMAINING_MIP_LEVELS,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            };

            const info = vk.DependencyInfo{
                .image_memory_barrier_count = 1,
                .p_image_memory_barriers = @ptrCast(@constCast(&to_present)),
            };
            device.cmdPipelineBarrier2(self.draw_cmd, &info);
        }

        try device.endCommandBuffer(self.draw_cmd);

        { // Submit
            const command_buffer_submit = vk.CommandBufferSubmitInfo{
                .command_buffer = self.draw_cmd,
                .device_mask = 0,
            };

            // this tells the GPU to wait on the image_acquired semaphore before starting all_transfer stage
            const wait_for_swapchain_image_acquired = vk.SemaphoreSubmitInfo{
                .semaphore = self.image_acquired,
                .stage_mask = .{ .color_attachment_output_bit = true },
                .value = 0,
                .device_index = 0,
            };

            // this tells the GPU to signal the rendering_done semaphore after all transfer commands (so draw image has been copied on swapchain and ready to present)
            const signal_on_rendering_done = vk.SemaphoreSubmitInfo{
                .semaphore = self.render_done,
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

            try device.queueSubmit2(self.rctx.graphics_queue.handle, 1, @ptrCast(&submit), self.fence);
        }

        { // Present
            const info = vk.PresentInfoKHR{
                .swapchain_count = 1,
                .p_swapchains = @ptrCast(&self.rctx.swapchain.handle),
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast(&self.render_done),
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
    }
};
