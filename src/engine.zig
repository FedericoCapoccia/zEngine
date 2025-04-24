const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("zglfw");
const vk = @import("vulkan");

const c = @import("c.zig");
const RenderContext = @import("vulkan/context.zig").RenderContext;

const log = std.log.scoped(.engine);

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

pub const Engine = struct {
    allocator: std.mem.Allocator,
    window: *glfw.Window = undefined,
    window_resized: bool = false,
    rctx: RenderContext = undefined,

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

        // ===================================================================
        // [SECTION] Render Context
        // ===================================================================
        self.rctx = RenderContext.new(self.allocator, self.window) catch |err| {
            std.log.err("Failed to create render context: {s}", .{@errorName(err)});
            return error.RenderContextCreationFailed;
        };
        errdefer self.rctx.destroy();

        // TODO: show window
    }

    pub fn shutdown(self: *Engine) void {
        std.log.info("Shutting down engine", .{});
        self.rctx.destroy();
        self.window.destroy();
        glfw.terminate();
    }

    pub fn run(self: *Engine) !void {
        std.log.info("Running...", .{});

        const enable_loop = false;
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
