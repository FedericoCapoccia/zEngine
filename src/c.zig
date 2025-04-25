pub const headers = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "");
    @cInclude("GLFW/glfw3.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("vk_mem_alloc.h");
    @cInclude("dcimgui.h");
    @cInclude("dcimgui_impl_vulkan.h");
    @cInclude("dcimgui_impl_glfw.h");
});
