const std = @import("std");
const builtin = @import("builtin");

const c = @import("c").c;
pub extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;

const vk = @import("vulkan");

const Window = @import("../window.zig").Window;
const core = @import("core.zig");

const enable_validation: bool = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

pub const VulkanContext = struct {
    allocator: std.mem.Allocator,
    window: *const Window,
    bw: vk.BaseWrapper = undefined,

    instance: vk.InstanceProxy = undefined,
    messenger: ?vk.DebugUtilsMessengerEXT = null,

    surface: vk.SurfaceKHR = .null_handle,

    gpu: vk.PhysicalDevice = .null_handle,
    gpu_details: core.gpu.Details = undefined,

    device: vk.DeviceProxy = undefined,

    vma: c.VmaAllocator = undefined,

    pub fn init(context: *VulkanContext) !void {
        context.bw = vk.BaseWrapper.load(glfwGetInstanceProcAddress);

        core.instance.create(context, enable_validation) catch |err| {
            std.log.err("Failed to create VulkanInstance: {s}", .{@errorName(err)});
            return error.InstanceCreationFailed;
        };
        errdefer core.instance.destroy(context);

        core.surface.create(context) catch |err| {
            std.log.err("Failed to create Vulkan Surface: {s}", .{@errorName(err)});
            return error.SurfaceCreationFailed;
        };
        errdefer core.surface.destroy(context);

        core.gpu.select(context) catch |err| {
            std.log.err("Failed to select PhysicalDevice: {s}", .{@errorName(err)});
            return error.PhysicalDeviceSelectionFailed;
        };
        std.log.info("Selected {s}", .{context.gpu_details.props.device_name});

        core.device.create(context) catch |err| {
            std.log.err("Failed to create logical device: {s}", .{@errorName(err)});
            return error.PhysicalDeviceSelectionFailed;
        };
        errdefer core.device.destroy(context);

        const vma_info = c.VmaAllocatorCreateInfo{
            .vulkanApiVersion = c.VK_API_VERSION_1_4,
            .instance = @ptrFromInt(@intFromEnum(context.instance.handle)),
            .physicalDevice = @ptrFromInt(@intFromEnum(context.gpu)),
            .device = @ptrFromInt(@intFromEnum(context.device.handle)),
        };

        if (c.vmaCreateAllocator(&vma_info, &context.vma) != c.VK_SUCCESS) {
            std.log.err("Failed to create VulkanMemoryAllocator", .{});
            return error.VmaAllocatorCreationFailed;
        }
        errdefer c.vmaDestroyAllocator(context.vma);
    }

    pub fn shutdown(self: *const VulkanContext) void {
        c.vmaDestroyAllocator(self.vma);
        core.device.destroy(self);
        core.surface.destroy(self);
        core.instance.destroy(self);
    }
};
