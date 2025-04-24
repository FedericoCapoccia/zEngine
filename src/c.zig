const vk = @import("vulkan");
const glfw = @import("zglfw");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "");
    @cInclude("GLFW/glfw3.h");
});

pub const GLFW_DONT_CARE = c.GLFW_DONT_CARE;

pub extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;
pub extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *const glfw.Window, allocation_callbacks: ?*const vk.AllocationCallbacks, surface: *vk.SurfaceKHR) vk.Result;
