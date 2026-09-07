module hello_triangle_sdl;

import gpu;
import gpu::util;
import sample_args;
import sample_capture;
import sample_window;
import std::io;

const char[*] TRIANGLE_VERT_SPIRV = $embed("shaders/triangle.vert.spv");
const char[*] TRIANGLE_FRAG_SPIRV = $embed("shaders/triangle.frag.spv");

const uint TEX_SIZE = 16;
const uint CHECKER_CELL = 4;

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("hello_triangle_sdl: FAIL (%s)", err);
        return 1;
    }
    io::printn("hello_triangle_sdl: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l hello triangle", 800, 600)!;
    defer sample_window::destroy_sample_window(&window);

    util::DeviceContextDesc desc = util::default_device_context_desc();
    desc.runtime.enable_vulkan_validation = true;
    desc.runtime.application_name = "hello_triangle_sdl";
    desc.device.unified_layouts = true;
    desc.create_surface = &sample_window::surface_factory;
    desc.surface_user_data = &window;
    sample_window::pixel_size(&window, &desc.swapchain.width, &desc.swapchain.height);
    desc.swapchain.present_mode = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX;
    desc.swapchain.debug_name = "hello_triangle_swapchain";
    util::DeviceContext context = util::create_device_context(&desc)!;
    defer util::destroy_device_context(&context);
    defer (void)gpu::wait_swapchain_presentations(&context.device, context.swapchain);
    gpu::Device* device = &context.device;
    gpu::SwapchainHandle swapchain = context.swapchain;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(device, swapchain)!;
    io::printfn("hello_triangle_sdl: unified layouts optimal %s",
        gpu::get_device_caps(device)!.unified_layouts_optimal ? "yes" : "no");

    gpu::TextureDesc tex_desc = {
        .width  = TEX_SIZE,
        .height = TEX_SIZE,
        .format = gpu::Format.RGBA8_UNORM,
        .usage  = { .sampled, .transfer_dst },
        .access = { .graphics },
    };
    gpu::TextureHandle checker = gpu::create_texture(device, &tex_desc)!;
    defer (void)gpu::destroy_texture(device, checker);
    gpu::TextureView tex_view = gpu::create_texture_view(device, checker, null)!;
    defer (void)gpu::destroy_texture_view(device, tex_view);
    gpu::SamplerDesc sampler_desc = { .min_filter = gpu::Filter.NEAREST, .mag_filter = gpu::Filter.NEAREST };
    TriangleRoot root = {
        .texture_index = tex_view.index,
        .sampler_index = gpu::intern_sampler(device, &sampler_desc)!,
    };

    gpu::AllocationDesc staging_desc = {
        .size         = TEX_SIZE * TEX_SIZE * 4,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
    };
    gpu::MappedGpuSpan staging = gpu::allocate_mapped_memory(device, &staging_desc)!;
    gpu::GpuAllocation staging_allocation = staging.span.allocation();
    defer (void)gpu::free_allocation(device, &staging_allocation);
    char[4][] texels = ((char[4]*)staging.bytes.ptr)[:TEX_SIZE * TEX_SIZE];
    foreach (i, &texel : texels) {
        bool light = ((i % TEX_SIZE) / CHECKER_CELL + (i / TEX_SIZE) / CHECKER_CELL) % 2 == 0;
        *texel = light ? { 230, 180, 60, 255 } : { 40, 90, 200, 255 };
    }
    gpu::flush_mapped_span(device, staging.span)!;

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = { .spirv = TRIANGLE_VERT_SPIRV[..], .entry_point = "main" },
        .fragment_shader = { .spirv = TRIANGLE_FRAG_SPIRV[..], .entry_point = "main" },
        .color_formats   = color_formats[..],
        .debug_name      = "hello_triangle",
    };
    gpu::PipelineHandle pipeline;
    defer if (pipeline.is_valid()) (void)gpu::destroy_pipeline(device, pipeline);

    bool checker_uploaded = false;
    long frame = 0;
    gpu::CompletionPoint last_graphics;
    defer if (last_graphics.is_valid()) (void)gpu::wait_completion(last_graphics, ulong::max);
    while (options.frames < 0 || frame < options.frames) {
        sample_window::WindowEvents events = sample_window::pump_events(&window);
        if (events.quit) break;
        if (events.resized) swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
        if (swapchain_info.dormant) {
            sample_window::throttle_dormant();
            continue;
        }
        if (!pipeline.is_valid() || color_formats[0] != swapchain_info.format) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
            if (pipeline.is_valid()) gpu::destroy_pipeline(device, pipeline)!;
            color_formats[0] = swapchain_info.format;
            pipeline = gpu::create_graphics_pipeline(device, &pipe_desc)!;
        }

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(device, swapchain, sample_window::FRAME_ACQUIRE_TIMEOUT_NS);
        if (catch err = acquired) {
            if (err == gpu::WAIT_TIMEOUT) continue;
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
            continue;
        }

        gpu::CommandList cmd = gpu::begin_commands(&context.command_allocator)!;
        defer (void)gpu::discard_commands(&cmd);
        if (!checker_uploaded) {
            gpu::BufferTextureCopyDesc upload = { .src = staging.span, .texture = checker };
            gpu::cmd_copy_buffer_to_texture(&cmd, &upload)!;
            gpu::TextureBarrier to_sampled = gpu::texture_transition(
                texture: checker,
                before:  { .layout = gpu::TextureLayout.TRANSFER_DESTINATION, .stages = { .transfer }, .access = { .write } },
                after:   gpu::sampled_at({ .fragment_shader }),
            )!;
            gpu::cmd_texture_barrier(&cmd, &to_sampled)!;
            checker_uploaded = true;
        }

        root.pulse = (float)(frame % 120) / 120.0f * 0.15f;
        gpu::ColorTargetDesc[1] colors = {{
            .view     = acquired.attachment_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.05f + root.pulse, 0.05f, 0.12f, 1.0f } },
        }};
        gpu::RenderPassDesc pass = { .colors = colors[..] };
        gpu::GraphicsState graphics = gpu::render_geometry_state(swapchain_info.width, swapchain_info.height)!;
        gpu::ColorTargetState[1] color_targets = { gpu::color_blend_disabled() };
        graphics.color.targets = color_targets[..];
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::cmd_bind_pipeline(&cmd, pipeline)!;
        gpu::cmd_set_graphics_state(&cmd, &graphics)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    (gpu::GpuAddress)0,
            fragment_root:  (gpu::GpuAddress)0,
            vertex_count:   3,
            instance_count: 1,
            inline_root:    gpu::@inline_root(&root),
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        sample_capture::Capture capture;
        if (options.capture_frame(frame)) {
            capture = sample_capture::record_capture(
                device:     device,
                commands:   &cmd,
                src:        acquired.texture,
                width:      swapchain_info.width,
                height:     swapchain_info.height,
                format:     swapchain_info.format,
                from_state: { .layout = gpu::TextureLayout.GENERAL, .stages = { .color_output }, .access = { .write } },
                access:     { .graphics },
            )!;
        }

        gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
        defer (void)gpu::discard_executable_commands(&lists[0]);
        gpu::SubmitDesc submit = {
            .command_lists    = lists[..],
            .readiness        = acquired.readiness,
            .readiness_before = { .color_output },
        };
        last_graphics = gpu::submit(context.queue, &submit)!;

        if (capture.is_valid()) sample_capture::finish_capture(&capture, last_graphics, options.screenshot_path)!;
        if (catch err = sample_window::present_when_ready(device, &acquired, last_graphics)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
        }
        frame++;
    }
}
