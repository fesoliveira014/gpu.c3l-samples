module minimal_triangle;

import gpu;
import gpu::util;
import sample_window;

fn void main() {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l triangle", 512, 512)!!;
    defer sample_window::destroy_sample_window(&window);

    util::DeviceContextDesc desc = util::default_device_context_desc();
    desc.device.unified_layouts = true;
    desc.create_surface = &sample_window::surface_factory;
    desc.surface_user_data = &window;
    desc.swapchain = { .width = 512, .height = 512, .srgb = true };
    util::DeviceContext context = util::create_device_context(&desc)!!;
    defer util::destroy_device_context(&context);
    defer (void)gpu::wait_swapchain_presentations(&context.device, context.swapchain);

    gpu::PipelineHandle pipeline = gpu::create_graphics_pipeline(&context.device, &&(gpu::GraphicsPipelineDesc){
        .vertex_shader   = { .spirv = $embed("shaders/triangle.vert.spv") },
        .fragment_shader = { .spirv = $embed("shaders/triangle.frag.spv") },
        .color_formats   = { context.swapchain_info.format },
    })!!;
    defer (void)gpu::destroy_pipeline(&context.device, pipeline);

    while (!sample_window::pump_events(&window).quit) {
        gpu::AcquiredImage image = gpu::acquire_next_image(&context.device, context.swapchain, gpu::TIMEOUT_INFINITE)!!;
        gpu::CommandList cmd = gpu::begin_commands(&context.command_allocator)!!;
        gpu::cmd_begin_render_pass(&cmd, &&(gpu::RenderPassDesc){
            .colors = { { .view = image.attachment_view, .load_op = CLEAR } },
        })!!;
        gpu::cmd_bind_pipeline(&cmd, pipeline)!!;
        gpu::GraphicsState graphics = gpu::render_geometry_state(context.swapchain_info.width, context.swapchain_info.height)!!;
        graphics.color.targets = { gpu::color_blend_disabled() };
        gpu::cmd_set_graphics_state(&cmd, &graphics)!!;
        gpu::cmd_draw(&cmd, (gpu::GpuAddress)0, (gpu::GpuAddress)0, 3, 1)!!;
        gpu::cmd_end_render_pass(&cmd)!!;
        gpu::CompletionPoint completion = gpu::submit(context.queue, &&(gpu::SubmitDesc){
            .command_lists    = { gpu::end_commands(&cmd)!! },
            .readiness        = image.readiness,
            .readiness_before = { .color_output },
        })!!;
        gpu::wait_completion(completion)!!;
        sample_window::present_when_ready(&context.device, &image, completion)!!;
    }
}
