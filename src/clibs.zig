pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
    @cInclude("vk_mem_alloc.h");
    @cDefine("GLFW_INCLUDE_NONE", "");
    @cInclude("GLFW/glfw3.h");
});

pub const win_native = @cImport({
    @cDefine("GLFW_EXPOSE_NATIVE_WIN32", {});
    @cInclude("GLFW/glfw3.h");
    @cInclude("GLFW/glfw3native.h");
    @cInclude("dwmapi.h");
});

// pub extern fn glfwGetPhysicalDevicePresentationSupport(instance: vk.Instance, pdev: vk.PhysicalDevice, queuefamily: u32) c_int;
