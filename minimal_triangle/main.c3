module minimal_triangle;

import gpu;
import sample_args;
import sample_capture;
import sample_window;
import std::io;

const char[*] TRIANGLE_VERT_SPIRV = $embed("shaders/triangle.vert.spv");
const char[*] TRIANGLE_FRAG_SPIRV = $embed("shaders/triangle.frag.spv");

const uint WIDTH = 512;
const uint HEIGHT = 512;

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("minimal_triangle: FAIL (%s)", err);
        return 1;
    }
    io::printn("minimal_triangle: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l triangle", WIDTH, HEIGHT)!;
    defer sample_window::destroy_sample_window(&window);
    gpu::RuntimeDesc runtime_desc = gpu::full_validation_runtime_desc();
    runtime_desc.application_name = "minimal_triangle";
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);
    gpu::Surface surface = sample_window::create_surface(&runtime, &window)!;
    defer (void)gpu::destroy_surface(&surface);

    gpu::DeviceDesc device_desc = { .surface = surface, .unified_layouts = true };
    gpu::AdapterList adapters = gpu::enumerate_adapters(&runtime)!;
    gpu::Device device;
    for (uint i = 0; i < adapters.count && !device.is_valid(); i++) {
        gpu::Adapter adapter = adapters.get(i)!;
        if (!gpu::supports_device_desc(&adapter, &device_desc)!.supported) continue;
        device = gpu::create_device(&adapter, &device_desc)!;
        io::printfn("Using %s", gpu::get_adapter_info(&adapter)!.name);
    }
    if (!device.is_valid()) return gpu::UNSUPPORTED_FEATURE~;
    defer (void)gpu::destroy_device(&device);
    gpu::Queue queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;
    gpu::CommandAllocator allocator = gpu::create_command_allocator(&device, queue)!;
    defer (void)gpu::destroy_command_allocator(&allocator);

    gpu::SwapchainDesc swapchain_desc = {
        .width            = WIDTH,
        .height           = HEIGHT,
        .preferred_format = gpu::Format.BGRA8_UNORM,
        .present_mode     = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX,
        .srgb             = true,
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = { .spirv = TRIANGLE_VERT_SPIRV[..] },
        .fragment_shader = { .spirv = TRIANGLE_FRAG_SPIRV[..] },
        .color_formats   = color_formats[..],
    };
    gpu::PipelineHandle pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
    defer (void)gpu::destroy_pipeline(&device, pipeline);

    gpu::CompletionPoint latest_completion;
    defer if (latest_completion.is_valid()) (void)gpu::wait_completion(latest_completion, ulong::max);
    for (long frame = 0; options.frames < 0 || frame < options.frames;) {
        sample_window::WindowEvents events = sample_window::pump_events(&window);
        if (events.quit) break;
        if (events.resized) swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
        if (swapchain_info.dormant) {
            sample_window::throttle_dormant();
            continue;
        }
        gpu::AcquiredImage? acquired = gpu::acquire_next_image(&device, swapchain, sample_window::FRAME_ACQUIRE_TIMEOUT_NS);
        if (catch err = acquired) {
            if (err == gpu::WAIT_TIMEOUT) continue;
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            continue;
        }

        gpu::CommandList cmd = gpu::begin_commands(&allocator)!;
        defer (void)gpu::discard_commands(&cmd);
        gpu::ColorTargetDesc[1] colors = {{
            .view     = acquired.attachment_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
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
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        sample_capture::Capture capture;
        if (options.capture_frame(frame)) {
            capture = sample_capture::record_capture(
                device:     &device,
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
        latest_completion = gpu::submit(queue, &submit)!;
        if (capture.is_valid()) sample_capture::finish_capture(&capture, latest_completion, options.screenshot_path)!;
        if (catch err = sample_window::present_when_ready(&device, &acquired, latest_completion)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
        }
        frame++;
    }
}
