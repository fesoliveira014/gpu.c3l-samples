module particle_sim;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_window;
import std::io;

const char[*] SIM_SPIRV  = $embed("shaders/sim.comp.spv");
const char[*] VERT_SPIRV = $embed("shaders/particle.vert.spv");
const char[*] FRAG_SPIRV = $embed("shaders/particle.frag.spv");

const usz  PARTICLE_BYTES = PARTICLE_COUNT * 32;
const float FRAME_DT = 1.0f / 60.0f;

fn uint pcg_hash(uint x) {
    uint state = x * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28) + 4)) ^ state) * 277803737u;
    return (word >> 22) ^ word;
}

fn float hash_unit(uint x) => (float)(pcg_hash(x) & 0xFFFFFF) / 16777215.0f;

fn void seed_particles(float* out) {
    for (uint i = 0; i < PARTICLE_COUNT; i++) {
        usz base = (usz)i * 8;
        out[base]     = hash_unit(i * 4) * 0.8f - 0.4f;
        out[base + 1] = hash_unit(i * 4 + 1) * 2.0f - 1.0f;
        out[base + 2] = hash_unit(i * 4 + 2) * 0.8f - 0.4f;
        out[base + 3] = hash_unit(i * 4 + 3) * 6.0f;
        out[base + 4] = 0.0f;
        out[base + 5] = 0.0f;
        out[base + 6] = 0.0f;
        out[base + 7] = (float)i * 0.61803f;
    }
}

fn gpu::BufferHandle? create_particle_buffer(gpu::Device* device, ZString name) {
    gpu::BufferDesc desc = {
        .size        = PARTICLE_BYTES,
        // Compute and graphics may use distinct queue families; share instead of transferring ownership.
        .usage       = { .storage, .addressable, .shared_queues },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = name,
    };
    return gpu::create_buffer(device, &desc);
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("particle_sim: FAIL (%s)", err);
        return 1;
    }
    io::printn("particle_sim: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l particle sim", 1024, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::RuntimeDesc runtime_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "particle_sim",
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);

    gpu::Surface surface = sample_window::create_surface(&runtime, &window)!;
    defer (void)gpu::destroy_surface(&surface);

    gpu::Device device = sample_window::create_presentation_device(&runtime, &surface)!;
    defer (void)gpu::destroy_device(&device);

    uint width;
    uint height;
    sample_window::pixel_size(&window, &width, &height);
    gpu::SwapchainDesc swapchain_desc = {
        .width            = width,
        .height           = height,
        .preferred_format = gpu::Format.BGRA8_UNORM,
        .present_mode     = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX,
        .srgb             = false,
        .debug_name       = "particles_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)gpu::destroy_swapchain(&device, swapchain);

    gpu::BufferHandle buffer_a = create_particle_buffer(&device, "particles_a")!;
    defer (void)gpu::destroy_buffer(&device, buffer_a);
    gpu::BufferHandle buffer_b = create_particle_buffer(&device, "particles_b")!;
    defer (void)gpu::destroy_buffer(&device, buffer_b);
    gpu::GpuSpan span_a = gpu::get_buffer_span(&device, buffer_a)!;
    gpu::GpuSpan span_b = gpu::get_buffer_span(&device, buffer_b)!;
    seed_particles((float*)span_a.cpu);
    gpu::flush_buffer(&device, buffer_a, 0, 0)!;

    // Sim signals, render waits: two submits per frame linked by this
    // timeline. Compute may use a distinct queue; the timeline orders access,
    // while shared particle buffers make cross-family access legal.
    gpu::SemaphoreDesc sem_desc = { .initial_value = (gpu::SemaphoreValue)0, .debug_name = "sim_to_render" };
    gpu::SemaphoreHandle sim_done = gpu::create_semaphore(&device, &sem_desc)!;
    defer (void)gpu::destroy_semaphore(&device, sim_done);

    gpu::ShaderDesc sim_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = SIM_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle sim_shader = gpu::create_shader(&device, &sim_sd)!;
    defer (void)gpu::destroy_shader(&device, sim_shader);
    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle vert = gpu::create_shader(&device, &vert_sd)!;
    defer (void)gpu::destroy_shader(&device, vert);
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle frag = gpu::create_shader(&device, &frag_sd)!;
    defer (void)gpu::destroy_shader(&device, frag);

    gpu::ComputePipelineDesc sim_pd = { .shader = sim_shader, .push_constant_size = gpu::RootPush::size, .debug_name = "particle_sim" };
    gpu::PipelineHandle sim_pipe = gpu::create_compute_pipeline(&device, &sim_pd)!;
    defer (void)gpu::destroy_pipeline(&device, sim_pipe);

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc draw_pd = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .blend           = {
            .enable    = true,
            .src_color = gpu::BlendFactor.ONE,
            .dst_color = gpu::BlendFactor.ONE,
            .color_op  = gpu::BlendOp.ADD,
            .src_alpha = gpu::BlendFactor.ONE,
            .dst_alpha = gpu::BlendFactor.ONE,
            .alpha_op  = gpu::BlendOp.ADD,
        },
        .color_formats   = color_formats[..],
        .debug_name      = "particle_draw",
    };
    gpu::PipelineHandle draw_pipe;
    bool draw_pipeline_valid = false;
    if (!swapchain_info.dormant) {
        draw_pipe = gpu::create_graphics_pipeline(&device, &draw_pd)!;
        draw_pipeline_valid = true;
    }
    defer {
        if (draw_pipeline_valid) (void)gpu::destroy_pipeline(&device, draw_pipe);
    }

    sample_camera::Mat4 view = sample_camera::look_at({ 0.0f, 0.6f, 2.6f }, { 0, 0, 0 }, { 0, 1, 0 });
    long frame = 0;
    bool running = true;
    while (running) {
        sample_window::WindowEvents events = sample_window::pump_events(&window);
        if (events.quit) break;
        if (events.resized) {
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
        }
        if (swapchain_info.dormant) {
            sample_window::throttle_dormant();
            continue;
        }
        if (!draw_pipeline_valid || color_formats[0] != swapchain_info.format) {
            gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
            if (draw_pipeline_valid) gpu::destroy_pipeline(&device, draw_pipe)!;
            draw_pipeline_valid = false;
            color_formats[0] = swapchain_info.format;
            draw_pipe = gpu::create_graphics_pipeline(&device, &draw_pd)!;
            draw_pipeline_valid = true;
        }

        gpu::FrameToken frame_token = gpu::begin_frame(&device)!;

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(&device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            gpu::end_frame(&frame_token)!;
            continue;
        }

        bool even = frame % 2 == 0;
        gpu::GpuSpan read_span = even ? span_a : span_b;
        gpu::GpuSpan write_span = even ? span_b : span_a;

        // Submit 1: simulation, signaling the timeline at compute completion.
        gpu::GpuSpan sim_span = gpu::alloc_frame_span(&frame_token, SimRoot::size, 16)!;
        SimRoot* sim_root = (SimRoot*)sim_span.cpu;
        sim_root.read_gpu  = read_span.gpu;
        sim_root.write_gpu = write_span.gpu;
        sim_root.count     = PARTICLE_COUNT;
        sim_root.dt        = FRAME_DT;
        sim_root.time      = (float)frame * FRAME_DT;

        gpu::CommandList sim_cmd = gpu::begin_commands(&device, gpu::QueueKind.COMPUTE)!;
        gpu::cmd_dispatch(
            commands: &sim_cmd,
            pipeline: sim_pipe,
            root:     sim_span.gpu,
            groups:   { (PARTICLE_COUNT + SIM_TILE - 1) / SIM_TILE, 1, 1 },
        )!;
        gpu::end_commands(&sim_cmd)!;
        gpu::CommandList[1] sim_lists = { sim_cmd };
        gpu::SemaphoreSignal[1] sim_signals = {{ .semaphore = sim_done, .value = (gpu::SemaphoreValue)(frame + 1), .stage = gpu::Stage.COMPUTE_SHADER }};
        gpu::SubmitDesc sim_submit = { .command_lists = sim_lists[..], .signals = sim_signals[..] };
        gpu::submit(&device, &sim_submit)!;

        // Submit 2: rendering, waiting on the freshly simulated state.
        gpu::GpuSpan draw_span = gpu::alloc_frame_span(&frame_token, ParticleDrawRoot::size, 16)!;
        ParticleDrawRoot* draw_root = (ParticleDrawRoot*)draw_span.cpu;
        sample_camera::Mat4 view_proj = sample_camera::mul(
            sample_camera::perspective(
                fov_y_radians: 1.0f,
                aspect:        (float)swapchain_info.width / (float)swapchain_info.height,
                near:          0.1f,
                far:           20.0f,
            ),
            view);
        for (uint c = 0; c < 4; c++) {
            gpu::Vec4f* cols = &draw_root.view_proj_c0;
            cols[c] = { view_proj[c * 4], view_proj[c * 4 + 1], view_proj[c * 4 + 2], view_proj[c * 4 + 3] };
        }
        draw_root.particles_gpu = write_span.gpu;
        draw_root.aspect        = (float)swapchain_info.width / (float)swapchain_info.height;
        draw_root.quad_size     = 0.0045f;

        gpu::CommandList cmd = gpu::begin_commands(&device, gpu::QueueKind.GRAPHICS)!;
        gpu::TextureUse swapchain_before;
        switch (acquired.prior_layout) {
            case gpu::TextureLayout.UNDEFINED:
                swapchain_before = gpu::TextureUse.UNDEFINED;
            case gpu::TextureLayout.PRESENT:
                swapchain_before = gpu::TextureUse.PRESENT;
            default:
                return gpu::INVALID_RESOURCE_STATE~;
        }
        gpu::TextureBarrier to_attach = gpu::texture_transition(
            texture: acquired.texture,
            before:  swapchain_before,
            after:   gpu::TextureUse.COLOR_ATTACHMENT,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_attach)!;

        gpu::ColorTargetDesc[1] colors = {{
            .texture  = acquired.texture,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.01f, 0.012f, 0.03f, 1.0f } },
        }};
        gpu::RenderPassDesc pass = {
            .colors = colors[..],
            .width  = swapchain_info.width,
            .height = swapchain_info.height,
        };
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::cmd_draw(
            commands:       &cmd,
            pipeline:       draw_pipe,
            vertex_root:    draw_span.gpu,
            fragment_root:  draw_span.gpu,
            vertex_count:   6,
            instance_count: PARTICLE_COUNT,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = {
            .texture       = acquired.texture,
            .before_stage  = gpu::Stage.COLOR_ATTACHMENT,
            .after_stage   = gpu::Stage.PRESENT,
            .before_hazard = gpu::Hazard.COLOR_WRITE,
            .after_hazard  = gpu::Hazard.PRESENT_READ,
            .old_layout    = gpu::TextureLayout.COLOR_ATTACHMENT,
            .new_layout    = gpu::TextureLayout.PRESENT,
        };
        gpu::cmd_texture_barrier(&cmd, &to_present)!;
        gpu::end_commands(&cmd)!;

        gpu::CommandList[1] draw_lists = { cmd };
        gpu::SemaphoreWait[1] draw_waits = {{ .semaphore = sim_done, .value = (gpu::SemaphoreValue)(frame + 1), .stage = gpu::Stage.VERTEX_SHADER }};
        gpu::SubmitDesc draw_submit = { .command_lists = draw_lists[..], .waits = draw_waits[..], .swapchain = swapchain };
        gpu::submit(&device, &draw_submit)!;

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                device:      &device,
                src:         acquired.texture,
                width:       swapchain_info.width,
                height:      swapchain_info.height,
                format:      swapchain_info.format,
                from_stage:  gpu::Stage.PRESENT,
                from_hazard: gpu::Hazard.PRESENT_READ,
                from_layout: gpu::TextureLayout.PRESENT,
                path:        options.screenshot_path,
            )!;
        }

        gpu::PresentDesc present_desc = { .swapchain = swapchain };
        if (catch err = gpu::present(&device, &present_desc)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
        }

        gpu::end_frame(&frame_token)!;

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
    gpu::wait_queue_idle(&device, gpu::QueueKind.COMPUTE)!;
}
