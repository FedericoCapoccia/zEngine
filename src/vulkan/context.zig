const std = @import("std");
const builtin = @import("builtin");

const vk = @import("vulkan");

const c = @import("../clibs.zig").c;

const Queue = struct {
    family: u32,
    handle: vk.Queue,
};

const RenderContext = struct {
    instance: vk.InstanceProxy,
    messenger: ?vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,
};
