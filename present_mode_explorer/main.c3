module present_mode_explorer;

import gpu;
import sample_args;
import sample_capture;
import sample_frame_upload;
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
    gpu::ColorTargetState[1] color_targets;
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
    sample_frame_upload::FrameUploadRing* upload_ring,
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
    gpu::CompletionPoint last_graphics;
    defer {
        if (last_graphics.is_valid()) {
            (void)gpu::wait_completion(last_graphics, ulong::max);
        }
    }

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

        if (!pipeline.valid || pipeline.color_targets[0].format != swapchain_info.format) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
            if (pipeline.valid) gpu::destroy_pipeline(device, pipeline.handle)!;
            pipeline.valid = false;
            pipeline.color_targets[0] = {
                .format     = swapchain_info.format,
                .write_mask = gpu::COLOR_WRITE_ALL,
            };
            pipeline.handle = gpu::create_graphics_pipeline(device, &pipeline.desc)!;
            pipeline.valid = true;
        }
        *width = swapchain_info.width;
        *height = swapchain_info.height;

        Clock acquire_clk = clock::now();
        gpu::AcquiredImage? acquired = gpu::acquire_next_image(device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) {
                swapchain_info = sample_window::recover_swapchain(device, swapchain, window)!;
            }
            (void)frame_clk.mark();
            continue;
        }
        double acquire_ms = ms(acquire_clk.mark());
        gpu::AttachmentViewHandle color_view = acquired.attachment_view;

        sample_frame_upload::FrameUploadBatch upload =
            sample_frame_upload::begin_frame_upload(upload_ring)!;
        defer catch {
            if (upload.ring != null) {
                (void)sample_frame_upload::cancel_frame_upload(&upload);
            }
        };
        gpu::GpuSpan root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload,
            size:      ExplorerRoot::size,
            alignment: 16,
        )!;
        ExplorerRoot* root = (ExplorerRoot*)gpu::get_span_mapping(device, root_span)!.ptr;
        float bar = (float)(frame % 100) / 100.0f;
        root.params = { (float)frame * 0.04f, bar, (float)*width, (float)*height };
        gpu::GpuAddress root_address = gpu::get_span_address(device, root_span)!;
        sample_frame_upload::flush_frame_upload(&upload)!;

        gpu::Queue graphics_queue = gpu::get_queue(device, gpu::QueueKind.GRAPHICS)!;

        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
        defer (void)gpu::discard_commands(&cmd);
        gpu::TextureBarrier to_attach = gpu::texture_transition(
            texture: acquired.texture,
            before:  acquired.prior_state,
            after:   {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_attach)!;

        gpu::ColorTargetDesc[1] colors = {{
            .view     = color_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0, 0, 0, 1 } },
        }};
        gpu::RenderPassDesc pass = { .colors = colors[..], .width = *width, .height = *height };
        gpu::cmd_bind_pipeline(&cmd, pipeline.handle)!;
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::DepthState depth_state = {};
        gpu::cmd_set_depth_state(&cmd, &depth_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    root_address,
            fragment_root:  root_address,
            vertex_count:   3,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = gpu::texture_transition(
            texture: acquired.texture,
            before:  {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
            after:   {
                .layout = gpu::TextureLayout.PRESENT,
            },
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_present)!;
        gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
        defer (void)gpu::discard_executable_commands(&lists[0]);
        gpu::SubmitDesc submit = {
            .command_lists    = lists[..],
            .readiness        = acquired.readiness,
            .readiness_before = { .color_output },
        };
        last_graphics = gpu::submit(graphics_queue, &submit)!;
        sample_frame_upload::retire_frame_upload(&upload, last_graphics)!;

        if (frame == capture_at) {
            sample_capture::capture_texture_png(
                device:              device,
                producer_completion: last_graphics,
                queue_kind:          gpu::QueueKind.GRAPHICS,
                src:         acquired.texture,
                width:       *width,
                height:      *height,
                format:      swapchain_info.format,
                from_state:  {
                    .layout = gpu::TextureLayout.PRESENT,
                },
                path:        screenshot_path,
            )!;
        }

        if (catch err = sample_window::present_when_ready(device, &acquired, last_graphics)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(device, swapchain, window)!;
            (void)frame_clk.mark();
            continue;
        }

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

    if (stats.frames > 0) {
        stats.mean_ms = total_ms / stats.frames;
        stats.acquire_ms = total_acquire_ms / stats.frames;
    }
    return stats;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l present-mode explorer", 800, 480)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::RuntimeDesc runtime_desc = {
        .backend                      = gpu::BackendKind.VULKAN,
        .contract_validation          = gpu::ContractValidation.FULL,
        .track_resource_lifetimes     = true,
        .enable_vulkan_validation     = true,
        .application_name             = "present_mode_explorer",
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);

    gpu::Surface surface = sample_window::create_surface(&runtime, &window)!;
    defer (void)gpu::destroy_surface(&surface);

    gpu::Device device = sample_window::create_presentation_device(&runtime, &surface)!;
    defer (void)gpu::destroy_device(&device);

    gpu::QueueRoles upload_access = { .graphics };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        &device,
            slot_capacity: ExplorerRoot::size,
            access:        upload_access,
            debug_name:    "present_mode_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

    uint width;
    uint height;
    sample_window::pixel_size(&window, &width, &height);

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = CARD_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode vert = gpu::prepare_shader_code(&vert_sd)!;
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = CARD_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode frag = gpu::prepare_shader_code(&frag_sd)!;

    TestcardPipeline pipeline = {};
    pipeline.desc = (gpu::GraphicsPipelineDesc){
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .colors          = pipeline.color_targets[..],
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
    defer {
        if (swapchain.is_valid()) {
            (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);
        }
    }
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    gpu::PresentModeSupport support = gpu::get_present_mode_support(&device, swapchain)!;
    if (!support.fifo) {
        io::printn("present_mode_explorer: driver does not report FIFO — spec violation");
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
            sample_window::destroy_swapchain_when_ready(&device, swapchain)!;
            swapchain = gpu::SWAPCHAIN_HANDLE_INVALID;
            gpu::SwapchainDesc mode_desc = probe_desc;
            mode_desc.present_mode = mode;
            mode_desc.debug_name   = "explorer_mode";
            swapchain = gpu::create_swapchain(&device, &surface, &mode_desc)!;
            swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
        }
        ModeStats stats = run_mode_window(
            device:          &device,
            upload_ring:     &upload_ring,
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
}
