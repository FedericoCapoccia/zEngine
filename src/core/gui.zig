const std = @import("std");
const builtin = @import("builtin");

const c = @import("c");
const config = @import("config");
const glfw = @import("zglfw");
const vk = @import("vulkan");

const vk_utils = @import("../vulkan/utils.zig");
const Timer = @import("timer.zig").Timer;

const log = std.log.scoped(.gui);

pub const Gui = struct {
    pub const CreateInfo = struct {
        window: *glfw.Window,
        instance: vk.Instance,
        physical_device: vk.PhysicalDevice,
        device: *const vk.DeviceProxy,
        qfamily: u32,
        queue: vk.Queue,
        min_image_count: u32,
        image_count: u32,
        target_format: vk.SurfaceFormatKHR,
    };

    context: *c.ImGuiContext,
    pool: vk.DescriptorPool,
    device: *const vk.DeviceProxy,

    pub fn new(info: CreateInfo) !Gui {
        log.info("Creating Gui", .{});
        var self: Gui = undefined;
        self.device = info.device;

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

        self.pool = try self.device.createDescriptorPool(&pool_create_info, null);
        self.context = c.ImGui_CreateContext(null).?;

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

        const font = @embedFile("../resources/jetbrainsmono.ttf");

        _ = c.ImFontAtlas_AddFontFromMemoryTTF(
            io.*.Fonts,
            @constCast(font),
            font.len,
            20.0,
            &font_cfg,
            null,
        );

        const scale_x, const scale_y = info.window.getContentScale();

        const style = c.ImGui_GetStyle();
        c.ImGui_StyleColorsDark(style);
        c.ImGuiStyle_ScaleAllSizes(style, @max(scale_x, scale_y));

        style.*.WindowRounding = 0.0;
        style.*.Colors[c.ImGuiCol_WindowBg].w = 1.0;

        for (0..c.ImGuiCol_COUNT) |idx| {
            const col = &style.*.Colors[idx];
            col.*.x = linearizeColorComponent(col.*.x);
            col.*.y = linearizeColorComponent(col.*.y);
            col.*.z = linearizeColorComponent(col.*.z);
        }

        _ = c.cImGui_ImplGlfw_InitForVulkan(@ptrCast(info.window), true);

        const imgui_pipeline_info = c.VkPipelineRenderingCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = @ptrCast(&info.target_format),
        };

        const imgui_init_info = c.ImGui_ImplVulkan_InitInfo{
            .Instance = @ptrFromInt(@intFromEnum(info.instance)),
            .PhysicalDevice = @ptrFromInt(@intFromEnum(info.physical_device)),
            .Device = @ptrFromInt(@intFromEnum(info.device.handle)),
            .QueueFamily = info.qfamily,
            .Queue = @ptrFromInt(@intFromEnum(info.queue)),
            .DescriptorPool = @ptrFromInt(@intFromEnum(self.pool)),
            .MinImageCount = info.min_image_count,
            .ImageCount = info.image_count,
            .MSAASamples = c.VK_SAMPLE_COUNT_1_BIT,
            .UseDynamicRendering = true,
            .PipelineRenderingCreateInfo = imgui_pipeline_info,
        };

        _ = c.cImGui_ImplVulkan_Init(@ptrCast(@constCast(&imgui_init_info)));
        _ = c.cImGui_ImplVulkan_CreateFontsTexture();

        return self;
    }

    pub fn destroy(self: *const Gui) void {
        log.info("Destroying Gui", .{});
        c.cImGui_ImplVulkan_Shutdown();
        self.device.destroyDescriptorPool(self.pool, null);
        c.cImGui_ImplGlfw_Shutdown();
        c.ImGui_DestroyContext(self.context);
    }

    pub fn onResize(self: *const Gui, min_image_count: u32) void {
        _ = self;
        c.cImGui_ImplVulkan_SetMinImageCount(min_image_count);
    }

    pub fn draw(self: *const Gui, cmd: vk.CommandBuffer, timer: *Timer) void {
        _ = self;
        c.cImGui_ImplVulkan_NewFrame();
        c.cImGui_ImplGlfw_NewFrame();
        c.ImGui_NewFrame();

        // c.ImGui_ShowDemoWindow(null);
        _ = c.ImGui_Begin("Tool", null, 0);
        c.ImGui_Text("Frame time: %.3f ms", timer.getFrametimeInMs());
        c.ImGui_Text("FPS: %d", timer.getFPS());
        c.ImGui_End();

        c.ImGui_Render();
        const data = c.ImGui_GetDrawData();
        c.cImGui_ImplVulkan_RenderDrawData(data, @ptrFromInt(@intFromEnum(cmd)));
    }
};

fn linearizeColorComponent(srgb: f32) f32 {
    return if (srgb <= 0.04045)
        srgb / 12.92
    else
        std.math.pow(f32, (srgb + 0.055) / 1.055, 2.4);
}
