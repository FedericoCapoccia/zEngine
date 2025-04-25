const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("zglfw");
const vk = @import("vulkan");

const c = @import("../c.zig");
const Swapchain = @import("swapchain.zig").Swapchain;
const vk_utils = @import("utils.zig");

const enable_validation: bool = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

const device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
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
    swapchain: Swapchain,
    // vulkan memory allocation

    pub const Queue = struct {
        family: u32,
        handle: vk.Queue,
    };

    pub fn new(allocator: std.mem.Allocator, window: *glfw.Window) !RenderContext {
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
        errdefer allocator.destroy(this.instance.wrapper);
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

            var max_score: u32 = 0;
            for (devices) |device| {
                const props = this.instance.getPhysicalDeviceProperties(device);
                log.debug("Found PhysicalDevice [{s}]", .{props.device_name});
                const score: u32 = switch (props.device_type) {
                    .discrete_gpu => 10,
                    .integrated_gpu => 5,
                    else => 1,
                };

                if (score > max_score) {
                    max_score = score;
                    this.physical_device = device;
                }
            }

            const props = this.instance.getPhysicalDeviceProperties(this.physical_device);
            log.info("Selected [{s}]", .{props.device_name});

            const supported_extensions = try this.instance.enumerateDeviceExtensionPropertiesAlloc(
                this.physical_device,
                null,
                allocator,
            );
            defer allocator.free(supported_extensions);
            vk_utils.logSupportedExtensions(supported_extensions);

            if (!vk_utils.supportsRequiredExtensions(supported_extensions, &device_extensions)) {
                return error.ExtensionNotPresent;
            }

            log.debug("Scanning Physical Device Queue Families:", .{});
            const queue_properties = try this.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(this.physical_device, allocator);
            defer allocator.free(queue_properties);

            for (queue_properties, 0..) |qprops, idx| {
                const flags = qprops.queue_flags;
                const supports_present = try this.instance.getPhysicalDeviceSurfaceSupportKHR(
                    this.physical_device,
                    @intCast(idx),
                    this.surface,
                );
                if (flags.graphics_bit and supports_present == vk.TRUE) {
                    std.log.debug("\tGraphics queue found [{d}]", .{idx});
                    this.graphics_queue = Queue{
                        .family = @intCast(idx),
                        .handle = .null_handle,
                    };
                    break;
                }
            }

            var compute_index: ?u32 = null;
            for (queue_properties, 0..) |qprops, idx| {
                const flags = qprops.queue_flags;
                if (!flags.graphics_bit and flags.compute_bit) {
                    std.log.debug("\tDedicated compute queue found [{d}]", .{idx});
                    compute_index = @intCast(idx);
                    break;
                }
            }

            if (compute_index == null) {
                std.log.warn("\tDedicated compute queue not found, falling back to graphics queue", .{});
                compute_index = this.graphics_queue.family;
            }

            this.compute_queue = Queue{
                .family = @intCast(compute_index.?),
                .handle = .null_handle,
            };

            var transfer_index: ?u32 = null;
            for (queue_properties, 0..) |qprops, idx| {
                const flags = qprops.queue_flags;
                if (!flags.graphics_bit and !flags.compute_bit and flags.transfer_bit) {
                    std.log.debug("\tDedicated transfer queue found [{d}]", .{idx});
                    transfer_index = @intCast(idx);
                    break;
                }
            }

            if (transfer_index == null) {
                std.log.warn("\tDedicated transfer queue not found, falling back to compute queue", .{});
                transfer_index = compute_index;
            }

            this.transfer_queue = Queue{
                .family = @intCast(transfer_index.?),
                .handle = .null_handle,
            };

            log.debug("===================================================", .{});
            log.debug("", .{});
        }

        // ===================================================================
        // [SECTION] Logical Device
        // ===================================================================
        {
            log.debug("Creating Logical Device", .{});
            const priorities = [_]f32{1.0};
            const graphics = this.graphics_queue.family;
            const compute = this.compute_queue.family;
            const transfer = this.transfer_queue.family;

            var queue_infos = std.ArrayList(vk.DeviceQueueCreateInfo).init(allocator);
            defer queue_infos.deinit();

            try queue_infos.append(vk.DeviceQueueCreateInfo{ // Graphics queue guarranteed
                .queue_family_index = graphics,
                .queue_count = 1,
                .p_queue_priorities = &priorities,
            });

            if (compute != graphics) {
                try queue_infos.append(vk.DeviceQueueCreateInfo{
                    .queue_family_index = compute,
                    .queue_count = 1,
                    .p_queue_priorities = &priorities,
                });
            }

            if (transfer != graphics and transfer != compute) {
                try queue_infos.append(vk.DeviceQueueCreateInfo{
                    .queue_family_index = transfer,
                    .queue_count = 1,
                    .p_queue_priorities = &priorities,
                });
            }

            _ = this.instance.getPhysicalDeviceFeatures(this.physical_device);

            const timeline_semaphore_feature = vk.PhysicalDeviceTimelineSemaphoreFeatures{ .timeline_semaphore = 1 };

            const dynamic_rendering_feature = vk.PhysicalDeviceDynamicRenderingFeatures{
                .dynamic_rendering = 1,
                .p_next = @ptrCast(@constCast(&timeline_semaphore_feature)),
            };

            const sync2_feature = vk.PhysicalDeviceSynchronization2Features{
                .synchronization_2 = 1,
                .p_next = @ptrCast(@constCast(&dynamic_rendering_feature)),
            };

            const info = vk.DeviceCreateInfo{
                .p_enabled_features = &.{},
                .p_queue_create_infos = queue_infos.items.ptr,
                .queue_create_info_count = @intCast(queue_infos.items.len),
                .pp_enabled_extension_names = &device_extensions,
                .enabled_extension_count = @intCast(device_extensions.len),
                .p_next = &sync2_feature,
            };

            const handle = try this.instance.createDevice(this.physical_device, &info, null);

            const wrapper = try allocator.create(vk.DeviceWrapper);
            errdefer allocator.destroy(wrapper);
            wrapper.* = vk.DeviceWrapper.load(handle, this.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);

            this.device = vk.DeviceProxy.init(handle, wrapper);
            this.graphics_queue.handle = this.device.getDeviceQueue(this.graphics_queue.family, 0);
            this.compute_queue.handle = this.device.getDeviceQueue(this.compute_queue.family, 0);
            this.transfer_queue.handle = this.device.getDeviceQueue(this.transfer_queue.family, 0);
        }
        errdefer allocator.destroy(this.device.wrapper);
        errdefer this.device.destroyDevice(null);

        // ===================================================================
        // [SECTION] Swapchain creation
        // ===================================================================
        {
            log.debug("Creating Swapchain", .{});
            const width, const height = window.getFramebufferSize();

            const info = Swapchain.Info{
                .instance = &this.instance,
                .surface = this.surface,
                .physical_device = this.physical_device,
                .extent = vk.Extent2D{ .width = @intCast(width), .height = @intCast(height) },
            };

            this.swapchain = Swapchain{ .device = this.device };
            try this.swapchain.createOrResize(info, allocator);
        }
        errdefer this.swapchain.destroy(allocator);

        return this;
    }

    pub fn destroy(self: *const RenderContext) void {
        self.device.deviceWaitIdle() catch {};
        log.info("Destroying render context", .{});

        self.swapchain.destroy(&self.device, self.allocator);

        self.device.destroyDevice(null);
        self.allocator.destroy(self.device.wrapper);

        self.instance.destroySurfaceKHR(self.surface, null);

        if (self.messenger) |mess| {
            self.instance.destroyDebugUtilsMessengerEXT(mess, null);
        }
        self.instance.destroyInstance(null);
        self.allocator.destroy(self.instance.wrapper);
    }
};
