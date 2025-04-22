const std = @import("std");

const Window = @import("window.zig").Window;
const Renderer = @import("renderer.zig").Renderer;

const utils = @import("renderer/utils.zig");
const vk = @import("vulkan");
const core = @import("renderer/core.zig");
const c = @import("clibs.zig").c;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    window: Window = undefined,
    renderer: Renderer = undefined,

    pub fn init(engine: *Engine) !void {
        std.log.info("Initializing engine", .{});

        engine.window = Window.init(800, 600, "zEngine") catch |err| {
            std.log.err("Failed to initialize window: {s}", .{@errorName(err)});
            return error.WindowCreationFailed;
        };
        errdefer engine.window.shutdown();
        engine.window.setTitle("Hello");

        engine.renderer = Renderer.new(engine.allocator, &engine.window) catch |err| {
            std.log.err("Failed to initialize renderer: {s}", .{@errorName(err)});
            return error.RendererCreationFailed;
        };
        errdefer engine.renderer.shutdown();

        engine.window.show();
    }

    pub fn shutdown(self: *Engine) void {
        std.log.info("Shutting down engine", .{});
        self.renderer.shutdown();
        self.window.shutdown();
    }

    pub fn draw(self: *Engine) !void {
        const idx = self.renderer.startFrame() catch |err| {
            if (err == error.OutOfDateKHR) {
                return;
            }

            return error.FailedToDraw;
        };

        const device = self.renderer.device;
        const draw_image: *core.image.AllocatedImage = &self.renderer.draw_image;
        const draw_extent = self.renderer.draw_extent;
        const qfamilies = self.renderer.qfamilies;

        const frame = self.renderer.getCurrentFrame();
        const swapchain_image = self.renderer.swapchain.images[idx];

        utils.transitionImage(device, frame, draw_image.image, .undefined, .color_attachment_optimal, qfamilies.graphics);

        draw_geometry(frame.cmd, device, draw_image.view, draw_extent, self.renderer.triangle_pipeline);

        utils.transitionImage(device, frame, draw_image.image, .color_attachment_optimal, .transfer_src_optimal, qfamilies.graphics);
        utils.transitionImage(device, frame, swapchain_image, .undefined, .transfer_dst_optimal, qfamilies.graphics);

        utils.copy_image(device, frame.cmd, draw_image.image, swapchain_image, draw_extent, self.renderer.swapchain.extent);

        utils.transitionImage(device, frame, swapchain_image, .transfer_dst_optimal, .present_src_khr, qfamilies.graphics);

        try self.renderer.endFrame(idx);
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
};
