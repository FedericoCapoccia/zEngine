const std = @import("std");

const vk = @import("vulkan");

const Window = @import("../window.zig").Window;

pub extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;

pub fn create(allocator: std.mem.Allocator, validation: bool) !vk.InstanceProxy {
    std.log.debug("Creating Vulkan instance", .{});

    const bw = vk.BaseWrapper.load(glfwGetInstanceProcAddress);

    const app_info = vk.ApplicationInfo{
        .p_engine_name = "zEngine",
        .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .p_application_name = "Simple Engine",
        .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .api_version = @bitCast(vk.API_VERSION_1_4),
    };

    const available_extensions = try bw.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
    const available_layers = try bw.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(available_extensions);
    defer allocator.free(available_layers);
    logAvailableLayersAndExtensions(available_extensions, available_layers);

    var extensions = try Window.getRequiredVulkanExtensions(allocator);
    var layers = std.ArrayList([*:0]const u8).init(allocator);
    if (validation) {
        try extensions.append(vk.extensions.ext_debug_utils.name);
        try layers.append("VK_LAYER_KHRONOS_validation");
    }
    defer extensions.deinit();
    defer layers.deinit();

    if (!supportsLayers(available_layers, layers.items)) {
        return error.LayerNotSupported;
    }
    std.log.debug("", .{});
    if (!supportsExtensions(available_extensions, extensions.items)) {
        return error.ExtensionNotSupported;
    }
    std.log.debug("---------------------------", .{});

    const create_info = vk.InstanceCreateInfo{
        .p_application_info = &app_info,
        .enabled_extension_count = @intCast(extensions.items.len),
        .pp_enabled_extension_names = extensions.items.ptr,
        .enabled_layer_count = @intCast(layers.items.len),
        .pp_enabled_layer_names = layers.items.ptr,
    };

    const handle = try bw.createInstance(&create_info, null);
    const wrapper = try allocator.create(vk.InstanceWrapper);
    errdefer allocator.destroy(wrapper);
    wrapper.* = vk.InstanceWrapper.load(handle, bw.dispatch.vkGetInstanceProcAddr.?);
    return vk.InstanceProxy.init(handle, wrapper);
}

pub fn destroy(instance: vk.InstanceProxy, messenger: ?vk.DebugUtilsMessengerEXT, allocator: std.mem.Allocator) void {
    if (messenger) |mess| {
        std.log.debug("Destroying DebugUtilsMessenger", .{});
        instance.destroyDebugUtilsMessengerEXT(mess, null);
    }
    std.log.debug("Destroying Vulkan instance", .{});
    instance.destroyInstance(null);
    allocator.destroy(instance.wrapper);
}

fn supportsLayers(avail: []vk.LayerProperties, required: []const [*:0]const u8) bool {
    std.log.debug("Required Instance Layers:", .{});
    if (required.len == 0) return true;
    var found: bool = false;
    for (required) |ext| {
        found = false;
        for (avail) |props| {
            if (found) break;
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.layer_name, 0))) {
                std.log.debug("\t{s} is supported", .{ext});
                found = true;
                break;
            }
        }

        if (!found) std.log.warn("\t{s} is not supported", .{ext});
    }

    return found;
}

fn supportsExtensions(avail: []vk.ExtensionProperties, required: []const [*:0]const u8) bool {
    std.log.debug("Required Instance Extensions:", .{});
    if (required.len == 0) return true;
    var found: bool = false;
    for (required) |ext| {
        found = false;
        for (avail) |props| {
            if (found) break;
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                std.log.debug("\t{s} is supported", .{ext});
                found = true;
                break;
            }
        }

        if (!found) std.log.warn("\t{s} is not supported", .{ext});
    }

    return found;
}

fn logAvailableLayersAndExtensions(ext: []vk.ExtensionProperties, lay: []vk.LayerProperties) void {
    std.log.debug("---------------------------", .{});
    std.log.debug("Available Instance Layers:", .{});
    for (lay) |ly| {
        std.log.debug("\t{s}", .{std.mem.sliceTo(&ly.layer_name, 0)});
    }
    std.log.debug("", .{});
    std.log.debug("Available Instance Extensions:", .{});
    for (ext) |e| {
        std.log.debug("\t{s} ", .{std.mem.sliceTo(&e.extension_name, 0)});
    }
    std.log.debug("", .{});
}

//=====================================================================================================================
// DEBUG UTILS MESSENGER EXT stuff
//=====================================================================================================================
pub fn createMessenger(instance: vk.InstanceProxy) !vk.DebugUtilsMessengerEXT {
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
        .pfn_user_callback = onValidation,
    };

    return try instance.createDebugUtilsMessengerEXT(&info, null);
}

fn onValidation(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.C) vk.Bool32 {
    _ = user_data;
    const log = std.log.scoped(.DebugUtilsMessenger);

    const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.p_message else "NO MESSAGE!";
    // if (callback_data) |cb_data| {
    //     if (std.mem.eql(u8, std.mem.span(cb_data.p_message_id_name.?), "VUID-VkSwapchainCreateInfoKHR-pNext-07781")) {
    //         return vk.FALSE;
    //     }
    // }

    const type_str = blk: { // NOTE: this is ugly as hell
        if (msg_type.general_bit_ext) {
            break :blk "general";
        } else if (msg_type.validation_bit_ext) {
            break :blk "validation";
        } else if (msg_type.performance_bit_ext) {
            break :blk "performance";
        } else if (msg_type.device_address_binding_bit_ext) {
            break :blk "device address";
        } else {
            unreachable;
        }
    };

    if (severity.error_bit_ext) {
        log.err("[{s}]. Message:\n {s}", .{ type_str, message });
    }

    if (severity.warning_bit_ext) {
        log.warn("[{s}]. Message:\n {s}", .{ type_str, message });
    }

    if (severity.info_bit_ext) {
        log.info("[{s}]. Message:\n {s}", .{ type_str, message });
    }

    if (severity.verbose_bit_ext) {
        log.debug("[{s}]. Message:\n {s}", .{ type_str, message });
    }

    return vk.FALSE;
}
