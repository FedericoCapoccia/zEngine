const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("zglfw");
const vk = @import("vulkan");

const c = @import("../c.zig");
const vk_utils = @import("utils.zig");

const enable_validation: bool = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

const log = std.log.scoped(.render_context);

pub const RenderContext = struct {
    allocator: std.mem.Allocator,
    instance: vk.InstanceProxy,
    messenger: ?vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,
    physical_device: vk.PhysicalDevice,
    device: vk.DeviceProxy,
    graphics_queue: Queue,
    compute_queue: Queue,
    transfer_queue: Queue,
    // swapchain
    // vulkan memory allocation

    pub const Queue = struct {
        family: u32,
        handle: vk.Queue,
    };

    pub fn new(allocator: std.mem.Allocator, window: *const glfw.Window) !RenderContext {
        log.info("Creating render context", .{});
        var this: RenderContext = undefined;
        this.allocator = allocator;

        const bw = vk.BaseWrapper.load(c.glfwGetInstanceProcAddress);

        // ===================================================================
        // [SECTION] Instance
        // ===================================================================
        {
            log.debug("", .{});
            log.debug("================ Instance Creation ================", .{});
            const application_info = vk.ApplicationInfo{
                .api_version = @bitCast(vk.API_VERSION_1_4),
                .p_engine_name = "zEngine",
                .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
                .p_application_name = "placeholder",
                .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            };

            const supported_extensions = try bw.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
            const supported_layers = try bw.enumerateInstanceLayerPropertiesAlloc(allocator);
            defer allocator.free(supported_extensions);
            defer allocator.free(supported_layers);

            vk_utils.logSupportedLayers(supported_layers);
            vk_utils.logSupportedExtensions(supported_extensions);

            var required_layers = std.ArrayList([*:0]const u8).init(allocator);
            var required_extensions = std.ArrayList([*:0]const u8).init(allocator);
            defer required_layers.deinit();
            defer required_extensions.deinit();

            if (enable_validation) {
                try required_extensions.append(vk.extensions.ext_debug_utils.name);
                try required_layers.append("VK_LAYER_KHRONOS_validation");
            }

            const glfw_extensions = try glfw.getRequiredInstanceExtensions();
            for (glfw_extensions) |extension| {
                try required_extensions.append(extension);
            }

            if (!vk_utils.supportsRequiredLayers(supported_layers, required_layers.items)) {
                return error.LayerNotPresent;
            }

            if (!vk_utils.supportsRequiredExtensions(supported_extensions, required_extensions.items)) {
                return error.ExtensionNotPresent;
            }

            const create_info = vk.InstanceCreateInfo{
                .p_application_info = &application_info,
                .enabled_extension_count = @intCast(required_extensions.items.len),
                .pp_enabled_extension_names = required_extensions.items.ptr,
                .enabled_layer_count = @intCast(required_layers.items.len),
                .pp_enabled_layer_names = required_layers.items.ptr,
            };

            const handle = try bw.createInstance(&create_info, null);
            const wrapper = try allocator.create(vk.InstanceWrapper);
            errdefer allocator.destroy(wrapper);
            wrapper.* = vk.InstanceWrapper.load(handle, c.glfwGetInstanceProcAddress);
            this.instance = vk.InstanceProxy.init(handle, wrapper);
            errdefer this.instance.destroyInstance(null);

            if (enable_validation) {
                const severity = vk.DebugUtilsMessageSeverityFlagsEXT{
                    .error_bit_ext = true,
                    .warning_bit_ext = true,
                };

                const type_ = vk.DebugUtilsMessageTypeFlagsEXT{
                    .general_bit_ext = true,
                    .validation_bit_ext = true,
                    .performance_bit_ext = true,
                };

                const info = vk.DebugUtilsMessengerCreateInfoEXT{
                    .message_severity = severity,
                    .message_type = type_,
                    .pfn_user_callback = vk_utils.onValidation,
                };

                this.messenger = try this.instance.createDebugUtilsMessengerEXT(&info, null);
            }

            log.debug("===================================================", .{});
            log.debug("", .{});
        }
        errdefer this.instance.destroyInstance(null);

        // ===================================================================
        // [SECTION] Surface
        // ===================================================================
        log.debug("Creating SurfaceKHR", .{});
        _ = c.glfwCreateWindowSurface(this.instance.handle, window, null, &this.surface);

        // ===================================================================
        // [SECTION] Physical Device
        // ===================================================================
        {
            log.debug("", .{});
            log.debug("============ Physical Device Selection ============", .{});
            const devices = try this.instance.enumeratePhysicalDevicesAlloc(allocator);
            defer allocator.free(devices);

            if (devices.len == 0) {
                return error.NoPhysicalDeviceFound;
            }

            log.debug("===================================================", .{});
            log.debug("", .{});
        }

        return this;
    }

    pub fn destroy(self: *const RenderContext) void {
        log.info("Destroying render context", .{});
        self.instance.destroySurfaceKHR(self.surface, null);

        if (self.messenger) |mess| {
            self.instance.destroyDebugUtilsMessengerEXT(mess, null);
        }
        self.instance.destroyInstance(null);
        self.allocator.destroy(self.instance.wrapper);
    }
};
