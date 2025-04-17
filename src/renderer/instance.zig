const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const VulkanContext = @import("context.zig").VulkanContext;

pub fn create(ctx: *VulkanContext, validation: bool) !void {
    std.log.debug("Creating Vulkan instance", .{});
    const app_info = vk.ApplicationInfo{
        .p_engine_name = "zEngine",
        .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .p_application_name = "Simple Engine",
        .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .api_version = @bitCast(vk.API_VERSION_1_4),
    };

    const available_extensions =
        try ctx.bw.enumerateInstanceExtensionPropertiesAlloc(null, ctx.allocator);
    const available_layers =
        try ctx.bw.enumerateInstanceLayerPropertiesAlloc(ctx.allocator);
    defer ctx.allocator.free(available_extensions);
    defer ctx.allocator.free(available_layers);
    logAvailableLayersAndExtensions(available_extensions, available_layers);

    var extensions = try ctx.window.getRequiredVulkanExtensions(ctx.allocator);
    var layers = std.ArrayList([*:0]const u8).init(ctx.allocator);
    if (validation) {
        try extensions.append(vk.extensions.ext_debug_utils.name);
        try layers.append("VK_LAYER_KHRONOS_validation");
    }
    defer extensions.deinit();
    defer layers.deinit();

    if (!try supportsLayers(available_layers, layers.items)) {
        return error.LayerNotSupported;
    }
    std.log.debug("", .{});
    if (!try supportsExtensions(available_extensions, extensions.items)) {
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

    const handle = try ctx.bw.createInstance(&create_info, null);
    const wrapper = try ctx.allocator.create(vk.InstanceWrapper);
    errdefer ctx.allocator.destroy(wrapper);
    wrapper.* = vk.InstanceWrapper.load(handle, ctx.bw.dispatch.vkGetInstanceProcAddr.?);
    ctx.instance = vk.InstanceProxy.init(handle, wrapper);

    if (validation) {
        ctx.messenger = try createMessenger(ctx.instance);
    }
}

pub fn destroy(ctx: *const VulkanContext) void {
    if (ctx.messenger) |mess| {
        std.log.debug("Destroying DebugUtilsMessenger", .{});
        ctx.instance.destroyDebugUtilsMessengerEXT(mess, null);
    }
    std.log.debug("Destroying Vulkan instance", .{});
    ctx.instance.destroyInstance(null);
    ctx.allocator.destroy(ctx.instance.wrapper);
}

fn supportsLayers(avail: []vk.LayerProperties, required: []const [*:0]const u8) !bool {
    std.log.debug("Required Instance Layers:", .{});
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

fn supportsExtensions(avail: []vk.ExtensionProperties, required: []const [*:0]const u8) !bool {
    std.log.debug("Required Instance Extensions:", .{});
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
fn createMessenger(instance: vk.InstanceProxy) !vk.DebugUtilsMessengerEXT {
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
