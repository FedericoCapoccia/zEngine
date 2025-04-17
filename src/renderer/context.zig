const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const c = @import("c").c;
const sdl = @import("zsdl3");
const vk = @import("vulkan");

const Window = @import("../window.zig").Window;
const core = @import("core.zig");

const enable_validation: bool = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

pub const VulkanContext = struct {
    instance: vk.InstanceProxy,
    _messenger: ?vk.DebugUtilsMessengerEXT,

    window: *const Window,
    surface: vk.SurfaceKHR,
    surface_details: core.surface.Details,

    gpu: vk.PhysicalDevice,
    gpu_details: core.gpu.Details,

    device: vk.DeviceProxy,
    graphics_queue: vk.Queue,
    compute_queue: vk.Queue,
    transfer_queue: vk.Queue,

    vma: c.VmaAllocator,

    _allocator: Allocator,
    _base_wrapper: vk.BaseWrapper,

    pub fn init(allocator: Allocator, window: *const Window) !VulkanContext {
        var self: VulkanContext = undefined;
        self._allocator = allocator;
        self.window = window;
        self._base_wrapper = vk.BaseWrapper.load(Window.getInstanceProcAddress());

        core.instance.create(&self, enable_validation) catch |err| {
            std.log.err("Failed to create VulkanInstance: {s}", .{@errorName(err)});
            return error.InstanceCreationFailed;
        };
        errdefer core.instance.destroy(&self);

        core.surface.create(&self) catch |err| {
            std.log.err("Failed to create Vulkan Surface: {s}", .{@errorName(err)});
            return error.SurfaceCreationFailed;
        };
        errdefer core.surface.destroy(&self);

        core.gpu.select(&self) catch |err| {
            std.log.err("Failed to select PhysicalDevice: {s}", .{@errorName(err)});
            return error.PhysicalDeviceSelectionFailed;
        };
        std.log.info("Selected {s}", .{self.gpu_details.props.device_name});

        try core.surface.queryDetails(&self);

        core.device.create(&self) catch |err| {
            std.log.err("Failed to create logical device: {s}", .{@errorName(err)});
            return error.PhysicalDeviceSelectionFailed;
        };
        errdefer core.device.destroy(&self);

        const vma_info = c.VmaAllocatorCreateInfo{
            .vulkanApiVersion = c.VK_API_VERSION_1_4,
            .instance = @ptrFromInt(@intFromEnum(self.instance.handle)),
            .physicalDevice = @ptrFromInt(@intFromEnum(self.gpu)),
            .device = @ptrFromInt(@intFromEnum(self.device.handle)),
        };

        if (c.vmaCreateAllocator(&vma_info, &self.vma) != c.VK_SUCCESS) {
            std.log.err("Failed to create VulkanMemoryAllocator", .{});
            return error.VmaAllocatorCreationFailed;
        }
        errdefer c.vmaDestroyAllocator(self.vma);

        return self;
    }

    pub fn shutdown(self: *VulkanContext) void {
        c.vmaDestroyAllocator(self.vma);
        core.device.destroy(self);
        core.surface.destroy(self);
        core.instance.destroy(self);
    }
};
