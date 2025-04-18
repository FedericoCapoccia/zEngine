pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
    @cInclude("vk_mem_alloc.h");
    @cDefine("GLFW_INCLUDE_NONE", "");
    @cInclude("GLFW/glfw3.h");
});

// pub extern fn glfwGetPhysicalDevicePresentationSupport(instance: vk.Instance, pdev: vk.PhysicalDevice, queuefamily: u32) c_int;
