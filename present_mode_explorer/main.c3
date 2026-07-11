module present_mode_explorer;

import gpu;
import sample_args;
import sample_capture;
import sample_window;
import std::io;
import std::time;

const char[*] CARD_VERT_SPIRV = $embed("shaders/testcard.vert.spv");
const char[*] CARD_FRAG_SPIRV = $embed("shaders/testcard.frag.spv");

const uint WARMUP_FRAMES = 10;
const long DEFAULT_FRAMES_PER_MODE = 120;

struct ModeStats {
    double mean_ms;
    double min_ms;
    double max_ms;
    double acquire_ms;
    long   frames;
}

struct TestcardPipeline {
    gpu::PipelineHandle handle;
    gpu::GraphicsPipelineDesc desc;
    gpu::Format[1] color_formats;
    bool valid;
}

fn double ms(NanoDuration d) => (double)(long)d / 1_000_000.0;

fn String mode_name(gpu::PresentMode mode) {
    switch (mode) {
        case gpu::PresentMode.FIFO:      return "FIFO     ";
        case gpu::PresentMode.MAILBOX:   return "MAILBOX  ";
        case gpu::PresentMode.IMMEDIATE: return "IMMEDIATE";
    }
}

fn bool mode_supported(gpu::PresentModeSupport support, gpu::PresentMode mode) {
    switch (mode) {
        case gpu::PresentMode.FIFO:      return support.fifo;
        case gpu::PresentMode.MAILBOX:   return support.mailbox;
        case gpu::PresentMode.IMMEDIATE: return support.immediate;
    }
}

fn gpu::TextureUse? swapchain_texture_use(gpu::TextureLayout layout) {
    switch (layout) {
        case gpu::TextureLayout.UNDEFINED: return gpu::TextureUse.UNDEFINED;
        case gpu::TextureLayout.PRESENT:   return gpu::TextureUse.PRESENT;
        default:                           return gpu::INVALID_RESOURCE_STATE~;
    }
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("present_mode_explorer: FAIL (%s)", err);
        return 1;
    }
    io::printn("present_mode_explorer: PASS");
    return 0;
}

<* Render `frames` frames in the swapchain's current mode, collecting pacing
   stats. Captures a screenshot on frame `capture_at` when non-negative. *>
fn ModeStats? run_mode_window(
    gpu::Device* device,
    gpu::SwapchainHandle swapchain,
    sample_window::SampleWindow* window,
    TestcardPipeline* pipeline,
    gpu::SwapchainInfo swapchain_info,
    uint* width,
    uint* height,
    long frames,
    long capture_at,
    String screenshot_path
) {
    ModeStats stats = { .min_ms = 1.0e9 };
    double total_ms = 0.0;
    double total_acquire_ms = 0.0;
    Clock frame_clk = clock::now();
    long frame = 0;

    while (frame < frames) {
        sample_window::WindowEvents events = sample_window::pump_events(window);
        if (events.quit) break;
        if (events.resized) {
            swapchain_info = sample_window::recover_swapchain(device, swapchain, window)!;
        }
        if (swapchain_info.dormant) {
            sample_window::throttle_dormant();
            (void)frame_clk.mark();
            continue;
        }

        if (!pipeline.valid || pipeline.color_formats[0] != swapchain_info.format) {
            gpu::wait_queue_idle(device, gpu::QueueKind.GRAPHICS)!;
            if (pipeline.valid) gpu::destroy_pipeline(device, pipeline.handle)!;
            pipeline.valid = false;
            pipeline.color_formats[0] = swapchain_info.format;
            pipeline.handle = gpu::create_graphics_pipeline(device, &pipeline.desc)!;
            pipeline.valid = true;
        }
        *width = swapchain_info.width;
        *height = swapchain_info.height;

        gpu::begin_frame(device)!;

        Clock acquire_clk = clock::now();
        gpu::AcquiredImage? acquired = gpu::acquire_next_image(device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) {
                swapchain_info = sample_window::recover_swapchain(device, swapchain, window)!;
            }
            gpu::end_frame(device)!;
            (void)frame_clk.mark();
            continue;
        }
        double acquire_ms = ms(acquire_clk.mark());

        gpu::GpuSpan root_span = gpu::alloc_frame_span(device, ExplorerRoot::size, 16)!;
        ExplorerRoot* root = (ExplorerRoot*)root_span.cpu;
        float bar = (float)(frame % 100) / 100.0f;
        root.params = { (float)frame * 0.04f, bar, (float)*width, (float)*height };

        gpu::CommandList cmd = gpu::begin_commands(device, gpu::QueueKind.GRAPHICS)!;
        gpu::TextureBarrier to_attach = gpu::texture_transition(
            texture: acquired.texture,
            before:  swapchain_texture_use(acquired.prior_layout)!,
            after:   gpu::TextureUse.COLOR_ATTACHMENT,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_attach)!;

        gpu::ColorTargetDesc[1] colors = {{
            .texture  = acquired.texture,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0, 0, 0, 1 } },
        }};
        gpu::RenderPassDesc pass = { .colors = colors[..], .width = *width, .height = *height };
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::cmd_draw(
            commands:       &cmd,
            pipeline:       pipeline.handle,
            vertex_root:    root_span.gpu,
            fragment_root:  root_span.gpu,
            vertex_count:   3,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = gpu::texture_transition(
            texture: acquired.texture,
            before:  gpu::TextureUse.COLOR_ATTACHMENT,
            after:   gpu::TextureUse.PRESENT,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_present)!;
        gpu::end_commands(device, &cmd)!;

        gpu::CommandList[1] lists = { cmd };
        gpu::SubmitDesc submit = { .command_lists = lists[..], .swapchain = swapchain };
        gpu::submit(device, &submit)!;

        if (frame == capture_at) {
            sample_capture::capture_texture_png(
                device:      device,
                src:         acquired.texture,
                width:       *width,
                height:      *height,
                format:      swapchain_info.format,
                from_stage:  gpu::Stage.PRESENT,
                from_hazard: gpu::Hazard.PRESENT_READ,
                from_layout: gpu::TextureLayout.PRESENT,
                path:        screenshot_path,
            )!;
        }

        gpu::PresentDesc present_desc = { .swapchain = swapchain };
        if (catch err = gpu::present(device, &present_desc)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(device, swapchain, window)!;
            gpu::end_frame(device)!;
            (void)frame_clk.mark();
            continue;
        }

        gpu::end_frame(device)!;

        double frame_ms = ms(frame_clk.mark());
        if (frame >= WARMUP_FRAMES) {
            total_ms += frame_ms;
            total_acquire_ms += acquire_ms;
            stats.frames++;
            if (frame_ms < stats.min_ms) stats.min_ms = frame_ms;
            if (frame_ms > stats.max_ms) stats.max_ms = frame_ms;
        }
        frame++;
    }

    gpu::wait_queue_idle(device, gpu::QueueKind.GRAPHICS)!;
    if (stats.frames > 0) {
        stats.mean_ms = total_ms / stats.frames;
        stats.acquire_ms = total_acquire_ms / stats.frames;
    }
    return stats;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l present-mode explorer", 800, 480)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::DeviceDesc device_desc = {
        .backend             = gpu::BackendKind.VULKAN,
        .enable_validation   = true,
        .enable_presentation = true,
        .frames_in_flight    = 2,
        .application_name    = "present_mode_explorer",
    };
    gpu::Device device = gpu::create_device(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    gpu::SurfaceDesc surface = sample_window::surface_desc_for(&window)!;
    uint width;
    uint height;
    sample_window::pixel_size(&window, &width, &height);

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = CARD_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle vert = gpu::create_shader(&device, &vert_sd)!;
    defer (void)gpu::destroy_shader(&device, vert);
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = CARD_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle frag = gpu::create_shader(&device, &frag_sd)!;
    defer (void)gpu::destroy_shader(&device, frag);

    TestcardPipeline pipeline = {};
    pipeline.desc = (gpu::GraphicsPipelineDesc){
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .color_formats   = pipeline.color_formats[..],
        .debug_name      = "testcard",
    };
    defer {
        if (pipeline.valid) (void)gpu::destroy_pipeline(&device, pipeline.handle);
    }

    // Probe swapchain: FIFO is spec-guaranteed, so this always succeeds and
    // gives the query a surface to inspect.
    gpu::SwapchainDesc probe_desc = {
        .width            = width,
        .height           = height,
        .preferred_format = gpu::Format.BGRA8_UNORM,
        .present_mode     = gpu::PresentMode.FIFO,
        .srgb             = false,
        .debug_name       = "explorer_probe",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &probe_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    gpu::PresentModeSupport support = gpu::get_present_mode_support(&device, swapchain)!;
    if (!support.fifo) {
        io::printn("present_mode_explorer: driver does not report FIFO — spec violation");
        gpu::destroy_swapchain(&device, swapchain)!;
        return gpu::UNSUPPORTED_FEATURE~;
    }

    long frames_per_mode = options.frames > 0 ? options.frames : DEFAULT_FRAMES_PER_MODE;
    gpu::PresentMode[3] modes = { gpu::PresentMode.FIFO, gpu::PresentMode.MAILBOX, gpu::PresentMode.IMMEDIATE };

    io::printfn("present_mode_explorer: support fifo=%s mailbox=%s immediate=%s, %d frames/mode",
        support.fifo ? "yes" : "no",
        support.mailbox ? "yes" : "no",
        support.immediate ? "yes" : "no",
        frames_per_mode);

    foreach (i, mode : modes) {
        if (!mode_supported(support, mode)) {
            io::printfn("  %s  skipped (unsupported)", mode_name(mode));
            continue;
        }
        // The probe swapchain is already FIFO; recreate for the others.
        if (i > 0) {
            gpu::destroy_swapchain(&device, swapchain)!;
            gpu::SwapchainDesc mode_desc = probe_desc;
            mode_desc.present_mode = mode;
            mode_desc.debug_name   = "explorer_mode";
            swapchain = gpu::create_swapchain(&device, &surface, &mode_desc)!;
            swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
        }
        ModeStats stats = run_mode_window(
            device:          &device,
            swapchain:       swapchain,
            window:          &window,
            pipeline:        &pipeline,
            swapchain_info:  swapchain_info,
            width:           &width,
            height:          &height,
            frames:          frames_per_mode,
            capture_at:      mode == gpu::PresentMode.FIFO && options.wants_screenshot() ? frames_per_mode - 1 : -1,
            screenshot_path: options.screenshot_path,
        )!;
        io::printfn("  %s  frame %6.2f ms mean (%.2f..%.2f)   acquire %5.2f ms   ~%.0f fps",
            mode_name(mode), stats.mean_ms, stats.min_ms, stats.max_ms, stats.acquire_ms,
            stats.mean_ms > 0.0 ? 1000.0 / stats.mean_ms : 0.0);
    }
    gpu::destroy_swapchain(&device, swapchain)!;
}
