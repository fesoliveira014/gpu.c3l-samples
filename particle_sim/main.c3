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

    gpu::GpuAllocation allocation_a = create_particle_allocation(&device, "particles_a")!;
    defer (void)gpu::free_allocation(&device, &allocation_a);
    gpu::GpuAllocation allocation_b = create_particle_allocation(&device, "particles_b")!;
    defer (void)gpu::free_allocation(&device, &allocation_b);
    gpu::GpuSpan span_a = gpu::get_allocation_span(&device, allocation_a)!;
    gpu::GpuSpan span_b = gpu::get_allocation_span(&device, allocation_b)!;
    gpu::Queue compute_queue = gpu::get_queue(&device, gpu::QueueKind.COMPUTE)!;
    {
        float[] seed_data = mem::new_array(float, PARTICLE_BYTES / float::size);
        defer mem::free(seed_data.ptr);
        seed_particles(seed_data.ptr);

        gpu::CommandList upload_cmd = gpu::begin_commands(compute_queue)!;
        defer (void)gpu::discard_commands(&upload_cmd);
        gpu::cmd_upload_buffer(
            &upload_cmd,
            span_a,
            ((char*)seed_data.ptr)[:PARTICLE_BYTES],
        )!;
        gpu::BufferBarrier seed_ready = {
            .span          = span_a,
            .before_stage  = gpu::Stage.TRANSFER,
            .after_stage   = gpu::Stage.COMPUTE_SHADER,
            .before_hazard = gpu::Hazard.TRANSFER_WRITE,
            .after_hazard  = gpu::Hazard.SHADER_READ,
        };
        gpu::cmd_buffer_barrier(&upload_cmd, &seed_ready)!;
        gpu::ExecutableCommandList[1] upload_lists = { gpu::end_commands(&upload_cmd)! };
        defer (void)gpu::discard_executable_commands(&upload_lists[0]);
        gpu::SubmitDesc upload_submit = { .command_lists = upload_lists[..] };
        gpu::CompletionPoint upload_completion = gpu::submit(compute_queue, &upload_submit)!;
        gpu::wait_completion(upload_completion, ulong::max)!;
    }
    gpu::GpuAddress span_a_address = gpu::get_span_address(&device, span_a)!;
    gpu::GpuAddress span_b_address = gpu::get_span_address(&device, span_b)!;

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

        gpu::FrameToken frame_token = gpu::begin_frame(&device)!;
        defer catch (void)gpu::end_frame(&frame_token);

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(&device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            gpu::end_frame(&frame_token)!;
            continue;
        }

        bool even = frame % 2 == 0;
        gpu::GpuAddress read_address = even ? span_a_address : span_b_address;
        gpu::GpuAddress write_address = even ? span_b_address : span_a_address;

        // The draw submission waits on this compute completion across queues.
        gpu::GpuSpan sim_span = gpu::alloc_frame_span(&frame_token, SimRoot::size, 16)!;
        SimRoot* sim_root = (SimRoot*)gpu::get_span_mapping(&device, sim_span)!.ptr;
        sim_root.read_gpu  = read_address;
        sim_root.write_gpu = write_address;
        sim_root.count     = PARTICLE_COUNT;
        sim_root.dt        = FRAME_DT;
        sim_root.time      = (float)frame * FRAME_DT;
        gpu::GpuAddress sim_root_address = gpu::get_span_address(&device, sim_span)!;

        gpu::CommandList sim_cmd = gpu::begin_commands(compute_queue)!;
        gpu::cmd_dispatch(
            commands: &sim_cmd,
            pipeline: sim_pipe,
            root:     sim_root_address,
            groups:   { (PARTICLE_COUNT + SIM_TILE - 1) / SIM_TILE, 1, 1 },
        )!;
        gpu::ExecutableCommandList sim_cmd_executable = gpu::end_commands(&sim_cmd)!;
        gpu::ExecutableCommandList[1] sim_lists = { sim_cmd_executable };
        gpu::SubmitDesc sim_submit = { .command_lists = sim_lists[..] };
        last_compute = gpu::submit(compute_queue, &sim_submit)!;

        gpu::GpuSpan draw_span = gpu::alloc_frame_span(&frame_token, ParticleDrawRoot::size, 16)!;
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

        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
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
            vertex_root:    draw_root_address,
            fragment_root:  draw_root_address,
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
        gpu::ExecutableCommandList cmd_executable = gpu::end_commands(&cmd)!;

        gpu::ExecutableCommandList[1] draw_lists = { cmd_executable };
        gpu::CompletionPoint[1] draw_waits = { last_compute };
        gpu::SubmitDesc draw_submit = {
            .command_lists    = draw_lists[..],
            .completion_waits = draw_waits[..],
            .readiness        = acquired.readiness,
        };
        last_graphics = gpu::submit(graphics_queue, &draw_submit)!;

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

        if (catch err = gpu::present(&device, &acquired, last_graphics)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
        }

        gpu::end_frame(&frame_token)!;

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
    if (last_compute.is_valid()) gpu::wait_completion(last_compute, ulong::max)!;
}
