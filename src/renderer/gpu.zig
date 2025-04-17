const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");

const VulkanContext = @import("context.zig").VulkanContext;

pub const Details = struct {
    pub const extensions = [_][*:0]const u8{
        vk.extensions.khr_swapchain.name,
        vk.extensions.khr_dynamic_rendering.name,
        vk.extensions.khr_synchronization_2.name,
        vk.extensions.khr_timeline_semaphore.name,
    };
    props: vk.PhysicalDeviceProperties,
    graphics_qfamily: u32,
    compute_qfamily: u32,
    transfer_qfamility: u32,
};

pub fn select(ctx: *VulkanContext) !void {
    std.log.debug("Selecting physical device", .{});
    const devices = try ctx.instance.enumeratePhysicalDevicesAlloc(ctx.allocator);
    defer ctx.allocator.free(devices);

    var candidate: ?vk.PhysicalDevice = null;
    var max_score: u32 = 0;
    var details: ?Details = null;

    for (devices) |pdev| {
        const props = ctx.instance.getPhysicalDeviceProperties(pdev);
        const score = rate(props);
        std.log.info("Found PhysicalDevice [{s}] score: {d}", .{ props.device_name, score });

        const has_ext_support = try supportsExtensions(pdev, ctx.instance, ctx.allocator);
        if (!has_ext_support) continue;

        const queues = try scanQueueFamilies(pdev, ctx.instance, ctx.allocator, ctx.surface);

        std.log.debug("---------------------------", .{});

        if (score > max_score) {
            max_score = score;
            candidate = pdev;
            details = Details{
                .props = props,
                .graphics_qfamily = queues.graphics,
                .compute_qfamily = queues.compute,
                .transfer_qfamility = queues.transfer,
            };
        }
    }

    if (candidate) |cand| {
        ctx.gpu = cand;
        ctx.gpu_details = details.?;
        return;
    }

    return error.NoSuitableGpu;
}

// by spec any queue that supports graphics or compute indirectly supports transfer aswell
const QueueFamilyBundle = struct {
    graphics: u32,
    compute: u32,
    transfer: u32,
};

fn scanQueueFamilies(
    pdev: vk.PhysicalDevice,
    instance: vk.InstanceProxy,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !QueueFamilyBundle {
    std.log.debug("Scanning Queues", .{});
    const queues = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(queues);

    // Find a family queue that supports Graphics operation and can present to surface
    var graphics_index: ?u32 = null;
    for (queues, 0..) |props, i| {
        const flags = props.queue_flags;
        const supports_present: vk.Bool32 = try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, @intCast(i), surface);

        if (flags.graphics_bit and supports_present == vk.TRUE) {
            std.log.debug("\tGraphics queue found [{d}]", .{i});
            graphics_index = @intCast(i);
            break;
        }
    }
    if (graphics_index == null) {
        std.log.err("\tPhysical Device doesn't expose any queue family that can present to surface", .{});
        return error.NoGraphicsFamilies;
    }

    var compute_index: ?u32 = null;
    for (queues, 0..) |props, i| {
        const flags = props.queue_flags;
        if (!flags.graphics_bit and flags.compute_bit) {
            std.log.debug("\tDedicated compute queue found [{d}]", .{i});
            compute_index = @intCast(i);
            break;
        }
    }

    if (compute_index == null) {
        std.log.warn("\tDedicated compute queue not found, falling back to graphics queue", .{});
        compute_index = graphics_index;
    }

    var transfer_index: ?u32 = null;
    for (queues, 0..) |props, i| {
        const flags = props.queue_flags;
        if (!flags.graphics_bit and !flags.compute_bit and flags.transfer_bit) {
            std.log.debug("\tDedicated transfer queue found [{d}]", .{i});
            transfer_index = @intCast(i);
            break;
        }
    }

    if (transfer_index == null) {
        std.log.warn("\tDedicated transfer queue not found, falling back to compute queue", .{});
        transfer_index = compute_index;
    }

    return QueueFamilyBundle{
        .graphics = graphics_index.?,
        .compute = compute_index.?,
        .transfer = transfer_index.?,
    };
}

fn logAvailableExtensions(ext: []vk.ExtensionProperties) void {
    std.log.debug("---------------------------", .{});
    std.log.debug("Available Device Extensions:", .{});
    for (ext) |e| {
        std.log.debug("\t{s} ", .{std.mem.sliceTo(&e.extension_name, 0)});
    }
    std.log.debug("", .{});
}

fn supportsExtensions(pdev: vk.PhysicalDevice, instance: vk.InstanceProxy, allocator: Allocator) !bool {
    const properties = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(properties);

    logAvailableExtensions(properties);

    std.log.debug("Required Device Extensions", .{});
    var found: bool = false;
    for (Details.extensions) |ext| {
        found = false;
        for (properties) |props| {
            if (found) break;
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                std.log.debug("\tExtension {s} is supported", .{ext});
                found = true;
                break;
            }
        }

        if (!found) std.log.warn("\tExtension {s} is not supported", .{ext});
    }

    std.log.debug("", .{});
    return found;
}

fn rate(props: vk.PhysicalDeviceProperties) u32 {
    var score: u32 = switch (props.device_type) {
        .discrete_gpu => 10000,
        .integrated_gpu => 5000,
        .cpu => 2000,
        else => 1000,
    };
    score += props.limits.max_image_dimension_2d;
    return score;
}
