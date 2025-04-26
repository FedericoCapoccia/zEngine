const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("zglfw");
const vk = @import("vulkan");

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

const AllocatedImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    format: vk.Format,
    extent: vk.Extent3D,
    alloc: c.VmaAllocation,
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
    }

    pub fn shutdown(self: *Engine) void {
        std.log.info("Shutting down engine", .{});

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
            glfw.pollEvents();
        }
    }

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
};
