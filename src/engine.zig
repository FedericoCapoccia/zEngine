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
var current_frame: u2 = 0;

fn getCurrentFrame(self: *const Engine) *const FrameData {
    return @ptrCast(@constCast(&self.frames[@intCast(self.current_frame % CONCURRENT_FRAMES)]));
}

const AllocatedImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    format: vk.Format,
    extent: vk.Extent3D,
    alloc: c.VmaAllocation,
};

const FrameData = struct {
    draw_cmd: vk.CommandBuffer = .null_handle,
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
    pipeline: vk.Pipeline = .null_handle,
    pipeline_layout: vk.PipelineLayout = .null_handle,

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
    }

    pub fn shutdown(self: *Engine) void {
        std.log.info("Shutting down engine", .{});
        self.rctx.device.deviceWaitIdle() catch {};

        self.rctx.device.destroyPipelineLayout(self.pipeline_layout, null);
        self.rctx.device.destroyPipeline(self.pipeline, null);

        for (&self.frames) |*frame| {
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

        const enable_loop = false;
        while (!self.window.shouldClose() and enable_loop) {
            glfw.pollEvents();
        }
    }
    // TODO:
    //  Swapchain holds an image_acquired semaphore per SwapchainImage and returned on acquireNext()
    //  Move Commands pool as a Engine resource because I need only 1 of each type per thread, FrameData will hold buffers
    //  After fence reset, reset frame's command pool

    // pub fn draw(self: *Engine) !void {
    //     const idx = self.renderer.startFrame() catch |err| {
    //         if (err == error.OutOfDateKHR) {
    //             return;
    //         }
    //
    //         return error.FailedToDraw;
    //     };
    //
    //     {
    //         c.ImGui_ShowDemoWindow(null);
    //         c.ImGui_Text("Hello, world %d", .{123});
    //         if (c.ImGui_Button("Save")) {
    //             std.log.info("Saved", .{});
    //         }
    //     }
    //
    //     c.ImGui_Render();
    //
    //     const device = self.renderer.device;
    //     const draw_image: *core.image.AllocatedImage = &self.renderer.draw_image;
    //     const draw_extent = self.renderer.draw_extent;
    //     const qfamilies = self.renderer.qfamilies;
    //
    //     const frame = self.renderer.getCurrentFrame();
    //     const swapchain_image = self.renderer.swapchain.images[idx];
    //
    //     utils.transitionImage(device, frame, draw_image.image, .undefined, .color_attachment_optimal, qfamilies.graphics);
    //
    //     draw_geometry(frame.cmd, device, draw_image.view, draw_extent, self.renderer.triangle_pipeline);
    //
    //     utils.transitionImage(device, frame, draw_image.image, .color_attachment_optimal, .transfer_src_optimal, qfamilies.graphics);
    //     utils.transitionImage(device, frame, swapchain_image, .undefined, .transfer_dst_optimal, qfamilies.graphics);
    //
    //     utils.copy_image(device, frame.cmd, draw_image.image, swapchain_image, draw_extent, self.renderer.swapchain.extent);
    //
    //     utils.transitionImage(device, frame, swapchain_image, .transfer_dst_optimal, .present_src_khr, qfamilies.graphics);
    //
    //     try self.renderer.endFrame(idx);
    // }
    //
    // fn draw_geometry(
    //     cmd: vk.CommandBuffer,
    //     device: vk.DeviceProxy,
    //     view: vk.ImageView,
    //     extent: vk.Extent2D,
    //     pipeline: vk.Pipeline,
    // ) void {
    //     const color_attachment = vk.RenderingAttachmentInfo{
    //         .image_view = view,
    //         .image_layout = .color_attachment_optimal,
    //         .load_op = .clear,
    //         .store_op = .store,
    //         .resolve_mode = .{},
    //         .resolve_image_layout = .undefined,
    //         .resolve_image_view = .null_handle,
    //         .clear_value = vk.ClearValue{
    //             .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } },
    //         },
    //     };
    //
    //     const rend_info = vk.RenderingInfo{
    //         .render_area = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
    //         .layer_count = 1,
    //         .color_attachment_count = 1,
    //         .p_color_attachments = @ptrCast(&color_attachment),
    //         .p_depth_attachment = null,
    //         .p_stencil_attachment = null,
    //         .view_mask = 0,
    //     };
    //
    //     device.cmdBeginRendering(cmd, &rend_info);
    //
    //     device.cmdBindPipeline(cmd, .graphics, pipeline);
    //
    //     const viewport = vk.Viewport{
    //         .x = 0,
    //         .y = 0,
    //         .width = @floatFromInt(extent.width),
    //         .height = @floatFromInt(extent.height),
    //         .min_depth = 0.0,
    //         .max_depth = 1.0,
    //     };
    //
    //     device.cmdSetViewport(cmd, 0, 1, @ptrCast(&viewport));
    //
    //     const scissor = vk.Rect2D{
    //         .offset = .{ .x = 0, .y = 0 },
    //         .extent = .{ .width = extent.width, .height = extent.height },
    //     };
    //
    //     device.cmdSetScissor(cmd, 0, 1, @ptrCast(&scissor));
    //
    //     device.cmdDraw(cmd, 3, 1, 0, 0);
    //
    //     const data = c.ImGui_GetDrawData();
    //     c.cImGui_ImplVulkan_RenderDrawData(data, @ptrFromInt(@intFromEnum(cmd)));
    //
    //     if (builtin.os.tag == .windows) {
    //         c.ImGui_UpdatePlatformWindows();
    //         c.ImGui_RenderPlatformWindowsDefault();
    //     }
    //
    //     device.cmdEndRendering(cmd);
    // }

    // FIXME: these are snippets for undo double gamma correction https://github.com/ocornut/imgui/issues/8271
    //  and to separate imgui stuff rendering from draw geometry

    // pub fn linearizeColorComponent(srgb: f32) f32 {
    //         return if (srgb <= 0.04045)
    //             srgb / 12.92
    //         else
    //             std.math.pow(f32, (srgb + 0.055) / 1.055, 2.4);
    //     }
    //
    //     for (0..c.ImGuiCol_COUNT) |idx| {
    //             const col = &style.*.Colors[idx];
    //             col.*.x = linearizeColorComponent(col.*.x);
    //             col.*.y = linearizeColorComponent(col.*.y);
    //             col.*.z = linearizeColorComponent(col.*.z);
    //         }
    //
    //
    //
    //         c.cImGui_ImplVulkan_NewFrame();
    //         c.cImGui_ImplGlfw_NewFrame();
    //         c.ImGui_NewFrame();
    //
    //         {
    //             c.ImGui_ShowDemoWindow(null);
    //             c.ImGui_Text("Hello, world %d", .{123});
    //             if (c.ImGui_Button("Save")) {
    //                 std.log.info("Saved", .{});
    //             }
    //         }
    //
    //         c.ImGui_Render();
    //
    //         self.renderer.device.cmdBeginRendering(frame.cmd, &rend_info);
    //
    //         const data = c.ImGui_GetDrawData();
    //         c.cImGui_ImplVulkan_RenderDrawData(data, @ptrFromInt(@intFromEnum(frame.cmd)));
    //
    //         if (builtin.os.tag == .windows) {
    //             c.ImGui_UpdatePlatformWindows();
    //             c.ImGui_RenderPlatformWindowsDefault();
    //         }
    //
    //         self.renderer.device.cmdEndRendering(frame.cmd);
};
