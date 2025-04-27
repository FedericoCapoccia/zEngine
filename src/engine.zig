const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("zglfw");
const vk = @import("vulkan");
const vk_utils = @import("vulkan/utils.zig");

const c = @import("c");
const RenderContext = @import("vulkan/context.zig").RenderContext;
const Swapchain = @import("vulkan/swapchain.zig").Swapchain;

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

const CONCURRENT_FRAMES: u2 = 2;
var frame_time: f64 = 0;

const AllocatedImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    format: vk.Format,
    extent: vk.Extent3D,
    alloc: c.VmaAllocation,
    last_layout: vk.ImageLayout,
};

const FrameData = struct {
    draw_cmd: vk.CommandBuffer = .null_handle,
    image_acquired: vk.Semaphore = .null_handle,
    rendering_done: vk.Semaphore = .null_handle,
    fence: vk.Fence = .null_handle,
};

pub const Engine = struct {
    // engine stuff
    allocator: std.mem.Allocator,
    window: *glfw.Window = undefined,
    window_resized: bool = false,
    rctx: RenderContext = undefined,

    // rendering stuff
    draw_image: AllocatedImage = undefined,
    draw_extent: vk.Extent2D = undefined,
    graphics_pool: vk.CommandPool = .null_handle,
    frames: [CONCURRENT_FRAMES]FrameData = .{FrameData{}} ** CONCURRENT_FRAMES,
    current_frame: u2 = 0,
    pipeline: vk.Pipeline = .null_handle,
    pipeline_layout: vk.PipelineLayout = .null_handle,

    imgui_pool: vk.DescriptorPool = .null_handle,
    imgui_ctx: *c.ImGuiContext = undefined,

    fn getCurrentFrame(self: *const Engine) *const FrameData {
        return @ptrCast(@constCast(&self.frames[@intCast(self.current_frame % CONCURRENT_FRAMES)]));
    }

    pub fn init(self: *Engine) !void {
        log.info("Initializing engine", .{});

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
        // [SECTION] Draw image creation
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
                // MUST manage image ownership manually because we might have dedicated transfer and compute queues
                .sharing_mode = .exclusive,
                .initial_layout = .undefined,
            };

            const alloc_info = c.VmaAllocationCreateInfo{
                .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
                .requiredFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            };

            var image: vk.Image = undefined;
            var image_alloc: c.VmaAllocation = undefined;
            const result = c.vmaCreateImage(self.rctx.vma, @ptrCast(&image_info), &alloc_info, @ptrCast(&image), &image_alloc, null);

            if (result != c.VK_SUCCESS) {
                return error.FailedToAllocateDrawImage;
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

            self.draw_image = AllocatedImage{
                .image = image,
                .alloc = image_alloc,
                .format = format,
                .extent = monitor_extent,
                .view = view,
                .last_layout = .undefined,
            };

            self.draw_extent = vk.Extent2D{
                .width = self.draw_image.extent.width,
                .height = self.draw_image.extent.height,
            };
        }
        errdefer {
            self.rctx.device.destroyImageView(self.draw_image.view, null);
            c.vmaDestroyImage(self.rctx.vma, @ptrFromInt(@intFromEnum(self.draw_image.image)), self.draw_image.alloc);
        }

        // ===================================================================
        // [SECTION] Frame Data Initialization
        // ===================================================================
        {
            log.debug("Initializing Frame Resources", .{});

            self.graphics_pool = try self.rctx.device.createCommandPool(&vk.CommandPoolCreateInfo{
                .queue_family_index = self.rctx.graphics_queue.family,
                .flags = .{ .transient_bit = true, .reset_command_buffer_bit = true },
            }, null);

            for (&self.frames) |*frame| {
                const semaphore_info = vk.SemaphoreCreateInfo{};
                const fence_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };

                frame.image_acquired = try self.rctx.device.createSemaphore(&semaphore_info, null);
                frame.rendering_done = try self.rctx.device.createSemaphore(&semaphore_info, null);
                frame.fence = try self.rctx.device.createFence(&fence_info, null);

                const alloc = vk.CommandBufferAllocateInfo{
                    .command_buffer_count = 1,
                    .command_pool = self.graphics_pool,
                    .level = .primary,
                };
                try self.rctx.device.allocateCommandBuffers(&alloc, @ptrCast(&frame.draw_cmd));
            }
        }
        errdefer self.rctx.device.destroyCommandPool(self.graphics_pool, null);
        errdefer {
            for (&self.frames) |*frame| {
                self.rctx.device.destroySemaphore(frame.*.rendering_done, null);
                self.rctx.device.destroyFence(frame.*.fence, null);
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
                .p_color_attachment_formats = @ptrCast(&self.draw_image.format),
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

            if (builtin.os.tag == .windows) {
                io.*.ConfigFlags |= c.ImGuiConfigFlags_DpiEnableScaleViewports;
                io.*.ConfigFlags |= c.ImGuiConfigFlags_ViewportsEnable;
            }

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
                .pColorAttachmentFormats = @ptrCast(&self.draw_image.format),
            };

            const imgui_init_info = c.ImGui_ImplVulkan_InitInfo{
                .Instance = @ptrFromInt(@intFromEnum(self.rctx.instance.handle)),
                .PhysicalDevice = @ptrFromInt(@intFromEnum(self.rctx.physical_device)),
                .Device = @ptrFromInt(@intFromEnum(self.rctx.device.handle)),
                .QueueFamily = self.rctx.graphics_queue.family,
                .Queue = @ptrFromInt(@intFromEnum(self.rctx.graphics_queue.handle)),
                .DescriptorPool = @ptrFromInt(@intFromEnum(self.imgui_pool)),
                .MinImageCount = CONCURRENT_FRAMES,
                .ImageCount = CONCURRENT_FRAMES,
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

        for (&self.frames) |*frame| {
            self.rctx.device.destroySemaphore(frame.*.image_acquired, null);
            self.rctx.device.destroySemaphore(frame.*.rendering_done, null);
            self.rctx.device.destroyFence(frame.*.fence, null);
        }

        self.rctx.device.destroyCommandPool(self.graphics_pool, null);

        self.rctx.device.destroyImageView(self.draw_image.view, null);
        c.vmaDestroyImage(self.rctx.vma, @ptrFromInt(@intFromEnum(self.draw_image.image)), self.draw_image.alloc);

        self.rctx.destroy();
        self.window.destroy();
        glfw.terminate();
    }

    pub fn run(self: *Engine) !void {
        std.log.info("Running...", .{});
        self.window.show();

        const enable_loop = true;
        while (!self.window.shouldClose() and enable_loop) {
            self.draw() catch |err| {
                log.warn("Failed to draw frame: {s}", .{@errorName(err)});
            };

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
    }

    fn draw(self: *Engine) !void {
        self.draw_extent.width = @min(self.rctx.swapchain.extent.width, self.draw_image.extent.width);
        self.draw_extent.height = @min(self.rctx.swapchain.extent.height, self.draw_image.extent.height);

        const frame = self.getCurrentFrame();
        const device: *const vk.DeviceProxy = &self.rctx.device;
        const swapchain: *Swapchain = &self.rctx.swapchain;

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

        try device.resetCommandBuffer(frame.draw_cmd, .{});

        const begin_info = vk.CommandBufferBeginInfo{ .flags = .{ .one_time_submit_bit = true } };
        try device.beginCommandBuffer(frame.draw_cmd, &begin_info);

        { // undefined to color attachment
            const barrier = vk.ImageMemoryBarrier2{
                .image = self.draw_image.image,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .old_layout = self.draw_image.last_layout,
                .new_layout = .color_attachment_optimal,
                .src_stage_mask = .{}, // NONE
                .src_access_mask = .{}, // NONE
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_access_mask = .{ .color_attachment_write_bit = true },

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
                .p_image_memory_barriers = @ptrCast(@constCast(&barrier)),
            };
            device.cmdPipelineBarrier2(frame.draw_cmd, &info);
        }

        c.cImGui_ImplVulkan_NewFrame();
        c.cImGui_ImplGlfw_NewFrame();
        c.ImGui_NewFrame();

        const color_attachment = vk.RenderingAttachmentInfo{
            .image_view = self.draw_image.view,
            .image_layout = .color_attachment_optimal,
            .load_op = .clear,
            .store_op = .store, // TODO: check what happens if it's .dont_care
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .resolve_image_view = .null_handle,
            .clear_value = vk.ClearValue{
                .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } },
            },
        };

        const rend_info = vk.RenderingInfo{
            .render_area = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.draw_extent },
            .layer_count = 1,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment),
            .p_depth_attachment = null,
            .p_stencil_attachment = null,
            .view_mask = 0,
        };

        device.cmdBeginRendering(frame.draw_cmd, &rend_info);

        { // draw geometry

            device.cmdBindPipeline(frame.draw_cmd, .graphics, self.pipeline);
            const viewport = vk.Viewport{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(self.draw_extent.width),
                .height = @floatFromInt(self.draw_extent.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            };

            device.cmdSetViewport(frame.draw_cmd, 0, 1, @ptrCast(&viewport));

            const scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = self.draw_extent.width, .height = self.draw_extent.height },
            };

            device.cmdSetScissor(frame.draw_cmd, 0, 1, @ptrCast(&scissor));

            device.cmdDraw(frame.draw_cmd, 3, 1, 0, 0);
        }

        { // Draw ImGui stuff

            c.ImGui_ShowDemoWindow(null);
            c.ImGui_Text("Frame time %f", @as(f64, frame_time * 1000));
            if (c.ImGui_Button("Save")) {
                std.log.info("Saved", .{});
            }

            c.ImGui_Render();

            const data = c.ImGui_GetDrawData();
            c.cImGui_ImplVulkan_RenderDrawData(data, @ptrFromInt(@intFromEnum(frame.draw_cmd)));

            if (builtin.os.tag == .windows) {
                c.ImGui_UpdatePlatformWindows();
                c.ImGui_RenderPlatformWindowsDefault();
            }
        }

        device.cmdEndRendering(frame.draw_cmd);

        { // color attachment to transfer_src for blit
            const barrier = vk.ImageMemoryBarrier2{
                .image = self.draw_image.image,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .old_layout = .color_attachment_optimal,
                .new_layout = .transfer_src_optimal,
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .src_access_mask = .{ .color_attachment_write_bit = true },
                .dst_stage_mask = .{ .blit_bit = true },
                .dst_access_mask = .{ .transfer_read_bit = true }, // TODO: maybe need both read and write

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
                .p_image_memory_barriers = @ptrCast(@constCast(&barrier)),
            };
            device.cmdPipelineBarrier2(frame.draw_cmd, &info);
            self.draw_image.last_layout = .transfer_src_optimal;
        }

        { // swapchain_image undefined to transfer_dst for blit
            const barrier = vk.ImageMemoryBarrier2{
                .image = acquired.image.handle,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{ .blit_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true }, // TODO: maybe need both read and write

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
                .p_image_memory_barriers = @ptrCast(@constCast(&barrier)),
            };
            device.cmdPipelineBarrier2(frame.draw_cmd, &info);
        }

        { // Blit draw image on swapchain image
            const src_offset_1 = vk.Offset3D{ .x = 0, .y = 0, .z = 0 };
            const src_offset_2 = vk.Offset3D{
                .x = @intCast(self.draw_extent.width),
                .y = @intCast(self.draw_extent.height),
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
                .src_image = self.draw_image.image,
                .src_image_layout = .transfer_src_optimal,
                .dst_image = acquired.image.handle,
                .dst_image_layout = .transfer_dst_optimal,
                .filter = .linear,
                .region_count = 1,
                .p_regions = @ptrCast(&region),
            };

            device.cmdBlitImage2(frame.draw_cmd, &info);
        }

        { // swapchain_image transfer_dst to present
            const barrier = vk.ImageMemoryBarrier2{
                .image = acquired.image.handle,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .old_layout = .transfer_dst_optimal,
                .new_layout = .present_src_khr,
                .src_stage_mask = .{ .blit_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
                .dst_access_mask = .{}, // ChatGPT said no access mask for presentation

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
                .p_image_memory_barriers = @ptrCast(@constCast(&barrier)),
            };
            device.cmdPipelineBarrier2(frame.draw_cmd, &info);
        }

        try device.endCommandBuffer(frame.draw_cmd);

        { // Submit
            const buffer_submit = vk.CommandBufferSubmitInfo{
                .command_buffer = frame.draw_cmd,
                .device_mask = 0,
            };

            const wait_info = vk.SemaphoreSubmitInfo{
                .semaphore = frame.image_acquired,
                .stage_mask = .{ .blit_bit = true },
                .device_index = 0,
                .value = 1,
            };

            const signal_info = vk.SemaphoreSubmitInfo{
                .semaphore = frame.rendering_done,
                .stage_mask = .{ .all_graphics_bit = true },
                .device_index = 0,
                .value = 1,
            };

            const submit_info = vk.SubmitInfo2{
                .command_buffer_info_count = 1,
                .p_command_buffer_infos = @ptrCast(&buffer_submit),
                .wait_semaphore_info_count = 1,
                .p_wait_semaphore_infos = @ptrCast(&wait_info),
                .signal_semaphore_info_count = 1,
                .p_signal_semaphore_infos = @ptrCast(&signal_info),
            };

            try device.queueSubmit2(
                self.rctx.graphics_queue.handle,
                1,
                @ptrCast(&submit_info),
                frame.fence,
            );
        }

        { // Present
            const info = vk.PresentInfoKHR{
                .swapchain_count = 1,
                .p_swapchains = @ptrCast(&self.rctx.swapchain.handle),
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast(&frame.rendering_done),
                .p_image_indices = @ptrCast(&acquired.image.index),
            };

            const res = device.queuePresentKHR(self.rctx.graphics_queue.handle, &info) catch |err| {
                if (err != error.OutOfDateKHR) {
                    std.log.err("Failed to present on the queue: {s}", .{@errorName(err)});
                    return error.QueuePresentFailed;
                }

                try self.resize();
                self.current_frame = (self.current_frame + 1) % CONCURRENT_FRAMES;
                return;
            };

            if (res == vk.Result.suboptimal_khr or self.window_resized) {
                try self.resize();
            }

            self.current_frame = (self.current_frame + 1) % CONCURRENT_FRAMES;
        }
    }
};
