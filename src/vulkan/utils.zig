const std = @import("std");
const builtin = @import("builtin");

const enable_tagging: bool = switch (builtin.mode) {
    .Debug => true,
    else => false,
};

const vk = @import("vulkan");

const log = std.log.scoped(.vk_utils);

// ===================================================================
// [SECTION] Utils
// ===================================================================
pub fn createShaderModule(device: vk.DeviceProxy, code: []const u8) !vk.ShaderModule {
    std.debug.assert(code.len % 4 == 0); // check for alignment

    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = code.len,
        .p_code = @alignCast(@ptrCast(code.ptr)),
    };

    return device.createShaderModule(&create_info, null);
}

pub fn layoutTransition(
    image: vk.Image,
    src_layout: vk.ImageLayout,
    dst_layout: vk.ImageLayout,
    src_access: vk.AccessFlags2,
    dst_access: vk.AccessFlags2,
    src_stage: vk.PipelineStageFlags2,
    dst_stage: vk.PipelineStageFlags2,
) vk.ImageMemoryBarrier2 {
    const barrier = vk.ImageMemoryBarrier2{
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
        .image = image,
        .old_layout = src_layout,
        .new_layout = dst_layout,
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .src_stage_mask = src_stage,
        .dst_stage_mask = dst_stage,
    };
    return barrier;
}

// ===================================================================
// [SECTION] Logging
// ===================================================================
pub fn logSupportedLayers(layers: []vk.LayerProperties) void {
    log.debug("Supported Layers:", .{});
    for (layers) |layer| {
        log.debug("\t{s}", .{std.mem.sliceTo(&layer.layer_name, 0)});
    }
}

pub fn logSupportedExtensions(extensions: []vk.ExtensionProperties) void {
    std.log.debug("Supported Extensions:", .{});
    for (extensions) |extension| {
        log.debug("\t{s} ", .{std.mem.sliceTo(&extension.extension_name, 0)});
    }
}

pub fn supportsRequiredExtensions(supported: []vk.ExtensionProperties, required: []const [*:0]const u8) bool {
    log.debug("Checking for extension support:", .{});
    if (required.len == 0) {
        log.debug("\tNo extension requested", .{});
        return true;
    }
    var all_supported = true;

    for (required) |req_ext| {
        var found = false;
        for (supported) |supp_ext| {
            if (std.mem.eql(u8, std.mem.span(req_ext), std.mem.sliceTo(&supp_ext.extension_name, 0))) {
                log.debug("\t{s} is supported", .{req_ext});
                found = true;
                break;
            }
        }

        if (!found) {
            log.warn("\t{s} is not supported", .{req_ext});
            all_supported = false;
        }
    }

    return all_supported;
}

pub fn supportsRequiredLayers(supported: []vk.LayerProperties, required: []const [*:0]const u8) bool {
    log.debug("Checking for layer support:", .{});
    if (required.len == 0) {
        log.debug("\tNo layers requested", .{});
        return true;
    }
    var all_supported = true;

    for (required) |req_lay| {
        var found = false;
        for (supported) |supp_lay| {
            if (std.mem.eql(u8, std.mem.span(req_lay), std.mem.sliceTo(&supp_lay.layer_name, 0))) {
                log.debug("\t{s} is supported", .{req_lay});
                found = true;
                break;
            }
        }

        if (!found) {
            log.warn("\t{s} is not supported", .{req_lay});
            all_supported = false;
        }
    }

    return all_supported;
}

pub fn onValidation(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.C) vk.Bool32 {
    _ = user_data;
    const dbg = std.log.scoped(.DebugUtilsMessenger);

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
        dbg.err("[{s}]. Message:\n {s}", .{ type_str, message });
    }

    if (severity.warning_bit_ext) {
        dbg.warn("[{s}]. Message:\n {s}", .{ type_str, message });
    }

    if (severity.info_bit_ext) {
        dbg.info("[{s}]. Message:\n {s}", .{ type_str, message });
    }

    if (severity.verbose_bit_ext) {
        dbg.debug("[{s}]. Message:\n {s}", .{ type_str, message });
    }

    return vk.FALSE;
}

// ===================================================================
// [SECTION] Debug Tagging
// ===================================================================

pub fn nameObject(device: *const vk.DeviceProxy, type_: vk.ObjectType, handle: u64, name: [*:0]const u8) !void {
    if (!enable_tagging) return;

    const info = vk.DebugUtilsObjectNameInfoEXT{
        .object_handle = handle,
        .object_type = type_,
        .p_object_name = name,
    };
    try device.setDebugUtilsObjectNameEXT(&info);
}

pub fn beginLabel(device: *const vk.DeviceProxy, cmd: vk.CommandBuffer, label: [*:0]const u8, color: [4]f32) void {
    if (!enable_tagging) return;

    const info = vk.DebugUtilsLabelEXT{
        .p_label_name = label,
        .color = color,
    };
    device.cmdBeginDebugUtilsLabelEXT(cmd, &info);
}

pub fn endLabel(device: *const vk.DeviceProxy, cmd: vk.CommandBuffer) void {
    if (!enable_tagging) return;
    device.cmdEndDebugUtilsLabelEXT(cmd);
}
