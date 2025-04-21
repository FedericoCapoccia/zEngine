const std = @import("std");

const vk = @import("vulkan");

pub const PipelineBuildInfo = struct {
    layout: vk.PipelineLayout,
    fragment_module: vk.ShaderModule,
    vertex_module: vk.ShaderModule,
    topology: vk.PrimitiveTopology,
    polygon_mode: vk.PolygonMode,
    cull_mode: vk.CullModeFlags,
    front_face: vk.FrontFace,
    color_format: vk.Format,
    depth_format: vk.Format,
};

pub fn create_pipeline(device: vk.DeviceProxy, info: PipelineBuildInfo) !vk.Pipeline {
    // configuration
    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{ // disable blending
        .blend_enable = vk.FALSE,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .dst_alpha_blend_factor = .zero,
        .src_alpha_blend_factor = .zero,
        .dst_color_blend_factor = .zero,
        .src_color_blend_factor = .zero,
        .color_blend_op = .add, // idk I guess these are default
        .alpha_blend_op = .add,
    };

    var shader_stages: [2]vk.PipelineShaderStageCreateInfo = undefined;
    shader_stages[0] = vk.PipelineShaderStageCreateInfo{
        .module = info.vertex_module,
        .stage = .{ .vertex_bit = true },
        .p_name = "main",
    };
    shader_stages[1] = vk.PipelineShaderStageCreateInfo{
        .module = info.fragment_module,
        .stage = .{ .fragment_bit = true },
        .p_name = "main",
    };

    // TODO: vertex and fragment

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = info.topology,
        .primitive_restart_enable = vk.FALSE,
    };

    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .polygon_mode = info.polygon_mode,
        .line_width = 1.0,
        .cull_mode = info.cull_mode,
        .front_face = info.front_face,
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .depth_bias_clamp = 0.0,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_slope_factor = 0.0,
    };

    const multisampling = vk.PipelineMultisampleStateCreateInfo{ // disable multisampling
        .sample_shading_enable = vk.FALSE,
        .rasterization_samples = .{ .@"1_bit" = true },
        .min_sample_shading = 1.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{ // disable depth test
        .depth_test_enable = vk.FALSE,
        .depth_write_enable = vk.FALSE,
        .depth_compare_op = .never,
        .depth_bounds_test_enable = vk.FALSE,
        .stencil_test_enable = vk.FALSE,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
        .front = .{
            .write_mask = 0,
            .depth_fail_op = .zero,
            .compare_mask = 0,
            .compare_op = .never,
            .fail_op = .zero,
            .pass_op = .zero,
            .reference = 0,
        },
        .back = .{
            .write_mask = 0,
            .depth_fail_op = .zero,
            .compare_mask = 0,
            .compare_op = .never,
            .fail_op = .zero,
            .pass_op = .zero,
            .reference = 0,
        },
    };

    const render_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&info.color_format),
        .depth_attachment_format = info.depth_format,
        .stencil_attachment_format = .undefined,
        .view_mask = 0,
    };

    // creatiion
    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .scissor_count = 1,
    };

    const color_blend_info = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_blend_attachment),
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{};

    const states: [2]vk.DynamicState = .{
        .viewport,
        .scissor,
    };

    const dynamic_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = 2,
        .p_dynamic_states = @ptrCast(&states),
    };

    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_stages = @ptrCast(&shader_stages),
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterizer,
        .p_multisample_state = &multisampling,
        .p_color_blend_state = &color_blend_info,
        .p_depth_stencil_state = &depth_stencil,
        .p_dynamic_state = &dynamic_info,
        .layout = info.layout,
        .p_next = &render_info,
        .subpass = 0,
        .base_pipeline_index = 0,
    };

    var pipeline: vk.Pipeline = .null_handle;
    _ = try device.createGraphicsPipelines(.null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline));

    return pipeline;
}
