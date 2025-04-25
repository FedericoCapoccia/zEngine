const zvk = @import("vulkan");
const zglfw = @import("zglfw");

pub const clibs = struct {
    pub const glfw = @cImport({
        @cDefine("GLFW_INCLUDE_NONE", "");
        @cInclude("GLFW/glfw3.h");
    });
    pub const vk = @cImport({
        @cInclude("vulkan/vulkan.h");
        @cInclude("vk_mem_alloc.h");
    });

    pub extern fn glfwGetInstanceProcAddress(instance: zvk.Instance, procname: [*:0]const u8) zvk.PfnVoidFunction;
    pub extern fn glfwCreateWindowSurface(instance: zvk.Instance, window: *const zglfw.Window, allocation_callbacks: ?*const zvk.AllocationCallbacks, surface: *zvk.SurfaceKHR) zvk.Result;
};
