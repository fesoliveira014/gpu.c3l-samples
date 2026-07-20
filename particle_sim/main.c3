module particle_sim;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;

const char[*] SIM_SPIRV  = $embed("shaders/sim.comp.spv");
const char[*] VERT_SPIRV = $embed("shaders/particle.vert.spv");
const char[*] FRAG_SPIRV = $embed("shaders/particle.frag.spv");

const usz  PARTICLE_BYTES = PARTICLE_COUNT * 32;
const float FRAME_DT = 1.0f / 60.0f;
const usz UPLOAD_BYTES_PER_SLOT = SimRoot::size + ParticleDrawRoot::size;

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

fn gpu::GpuAllocation? create_particle_allocation(gpu::Device* device, ZString name) {
    gpu::AllocationDesc desc = {
        .size         = PARTICLE_BYTES,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics, .compute },
        .debug_name   = name,
    };
    return gpu::allocate_memory(device, &desc);
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

    gpu::QueueRoles upload_access = { .graphics, .compute };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        &device,
            slot_capacity: UPLOAD_BYTES_PER_SLOT,
            access:        upload_access,
            debug_name:    "particle_root_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

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
    defer (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);

    gpu::GpuAllocation allocation_a = create_particle_allocation(&device, "particles_a")!;
    defer (void)gpu::free_allocation(&device, &allocation_a);
    gpu::GpuAllocation allocation_b = create_particle_allocation(&device, "particles_b")!;
    defer (void)gpu::free_allocation(&device, &allocation_b);
    gpu::GpuSpan span_a = gpu::get_allocation_span(&device, allocation_a)!;
    gpu::GpuSpan span_b = gpu::get_allocation_span(&device, allocation_b)!;
    gpu::Queue compute_queue = gpu::get_queue(&device, gpu::QueueKind.COMPUTE)!;
    {
        gpu::QueueRoles seed_access = { .compute };
        gpu::AllocationDesc seed_desc = {
            .size         = PARTICLE_BYTES,
            .alignment    = 16,
            .memory_class = gpu::MemoryClass.CPU_WRITE,
            .access       = seed_access,
            .debug_name   = "particle_seed_upload",
        };
        gpu::GpuAllocation seed_upload = gpu::allocate_memory(&device, &seed_desc)!;
        defer (void)gpu::free_allocation(&device, &seed_upload);
        gpu::GpuSpan seed_span = gpu::get_allocation_span(&device, seed_upload)!;
        seed_particles((float*)gpu::get_span_mapping(&device, seed_span)!.ptr);
        gpu::flush_mapped_span(&device, seed_span)!;

        gpu::CommandList upload_cmd = gpu::begin_commands(compute_queue)!;
        defer (void)gpu::discard_commands(&upload_cmd);
        gpu::Barrier seed_visible = {
            .before = { .host = true },
            .after = { .transfer = true },
        };
        gpu::cmd_barrier(&upload_cmd, &seed_visible)!;
        gpu::BufferCopyDesc seed_copy = {
            .src = seed_span,
            .dst = span_a,
        };
        gpu::cmd_copy_buffer(&upload_cmd, &seed_copy)!;
        gpu::Barrier seed_ready = {
            .before = { .transfer = true },
            .after = { .compute = true },
        };
        gpu::cmd_barrier(&upload_cmd, &seed_ready)!;
        gpu::ExecutableCommandList[1] upload_lists = { gpu::end_commands(&upload_cmd)! };
        defer (void)gpu::discard_executable_commands(&upload_lists[0]);
        gpu::SubmitDesc upload_submit = { .command_lists = upload_lists[..] };
        gpu::CompletionPoint upload_completion = gpu::submit(compute_queue, &upload_submit)!;
        gpu::wait_completion(upload_completion, ulong::max)!;
    }
    gpu::GpuAddress span_a_address = gpu::get_span_address(&device, span_a)!;
    gpu::GpuAddress span_b_address = gpu::get_span_address(&device, span_b)!;

    gpu::ShaderDesc sim_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = SIM_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode sim_shader = gpu::prepare_shader_code(&sim_sd)!;
    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode vert = gpu::prepare_shader_code(&vert_sd)!;
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode frag = gpu::prepare_shader_code(&frag_sd)!;

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
    gpu::CompletionPoint last_compute;
    gpu::CompletionPoint last_graphics;
    defer {
        if (last_graphics.is_valid()) (void)gpu::wait_completion(last_graphics, ulong::max);
        if (last_compute.is_valid()) (void)gpu::wait_completion(last_compute, ulong::max);
    }
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
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
            if (draw_pipeline_valid) gpu::destroy_pipeline(&device, draw_pipe)!;
            draw_pipeline_valid = false;
            color_formats[0] = swapchain_info.format;
            draw_pipe = gpu::create_graphics_pipeline(&device, &draw_pd)!;
            draw_pipeline_valid = true;
        }

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(&device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            continue;
        }

        sample_frame_upload::FrameUploadBatch upload_batch =
            sample_frame_upload::begin_frame_upload(&upload_ring)!;
        gpu::CompletionPoint batch_completion;
        defer catch {
            if (upload_batch.ring != null) {
                if (batch_completion.is_valid()) {
                    (void)gpu::wait_completion(batch_completion, ulong::max);
                }
                (void)sample_frame_upload::cancel_frame_upload(&upload_batch);
            }
        };

        bool even = frame % 2 == 0;
        gpu::GpuAddress read_address = even ? span_a_address : span_b_address;
        gpu::GpuAddress write_address = even ? span_b_address : span_a_address;

        gpu::GpuSpan sim_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      SimRoot::size,
            alignment: 16,
        )!;
        SimRoot* sim_root = (SimRoot*)gpu::get_span_mapping(&device, sim_span)!.ptr;
        sim_root.read_gpu  = read_address;
        sim_root.write_gpu = write_address;
        sim_root.count     = PARTICLE_COUNT;
        sim_root.dt        = FRAME_DT;
        sim_root.time      = (float)frame * FRAME_DT;
        gpu::GpuAddress sim_root_address = gpu::get_span_address(&device, sim_span)!;

        gpu::GpuSpan draw_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      ParticleDrawRoot::size,
            alignment: 16,
        )!;
        ParticleDrawRoot* draw_root = (ParticleDrawRoot*)gpu::get_span_mapping(&device, draw_span)!.ptr;
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
        draw_root.particles_gpu = write_address;
        draw_root.aspect        = (float)swapchain_info.width / (float)swapchain_info.height;
        draw_root.quad_size     = 0.0045f;
        gpu::GpuAddress draw_root_address = gpu::get_span_address(&device, draw_span)!;
        sample_frame_upload::flush_frame_upload(&upload_batch)!;

        gpu::CommandList sim_cmd = gpu::begin_commands(compute_queue)!;
        defer (void)gpu::discard_commands(&sim_cmd);
        gpu::cmd_bind_pipeline(&sim_cmd, sim_pipe)!;
        gpu::cmd_dispatch(
            commands: &sim_cmd,
            root:     sim_root_address,
            groups:   { (PARTICLE_COUNT + SIM_TILE - 1) / SIM_TILE, 1, 1 },
        )!;
        gpu::ExecutableCommandList[1] sim_lists = { gpu::end_commands(&sim_cmd)! };
        defer (void)gpu::discard_executable_commands(&sim_lists[0]);
        gpu::SubmitDesc sim_submit = { .command_lists = sim_lists[..] };
        last_compute = gpu::submit(compute_queue, &sim_submit)!;
        batch_completion = last_compute;

        // The draw submission waits on this compute completion across queues.
        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;
        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
        defer (void)gpu::discard_commands(&cmd);
        gpu::TextureUse swapchain_before;
        switch (acquired.prior_use) {
            case gpu::TextureUse.UNDEFINED:
                swapchain_before = gpu::TextureUse.UNDEFINED;
            case gpu::TextureUse.PRESENT:
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
        gpu::cmd_bind_pipeline(&cmd, draw_pipe)!;
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::DepthState depth_state = {};
        gpu::cmd_set_depth_state(&cmd, &depth_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    draw_root_address,
            fragment_root:  draw_root_address,
            vertex_count:   6,
            instance_count: PARTICLE_COUNT,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = {
            .texture       = acquired.texture,
            .before        = gpu::TextureUse.COLOR_ATTACHMENT,
            .after         = gpu::TextureUse.PRESENT,
        };
        gpu::cmd_texture_barrier(&cmd, &to_present)!;
        gpu::ExecutableCommandList[1] draw_lists = { gpu::end_commands(&cmd)! };
        defer (void)gpu::discard_executable_commands(&draw_lists[0]);
        gpu::CompletionPoint[1] draw_waits = { last_compute };
        gpu::SubmitDesc draw_submit = {
            .command_lists    = draw_lists[..],
            .completion_waits = draw_waits[..],
            .readiness        = acquired.readiness,
        };
        last_graphics = gpu::submit(graphics_queue, &draw_submit)!;
        batch_completion = last_graphics;
        sample_frame_upload::retire_frame_upload(&upload_batch, last_graphics)!;

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                device:              &device,
                producer_completion: last_graphics,
                queue_kind:          gpu::QueueKind.GRAPHICS,
                src:         acquired.texture,
                width:       swapchain_info.width,
                height:      swapchain_info.height,
                format:      swapchain_info.format,
                from_use:    gpu::TextureUse.PRESENT,
                path:        options.screenshot_path,
            )!;
        }

        if (catch err = sample_window::present_when_ready(&device, &acquired, last_graphics)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
        }

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
    if (last_compute.is_valid()) gpu::wait_completion(last_compute, ulong::max)!;
}
