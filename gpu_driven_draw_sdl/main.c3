module gpu_driven_draw_sdl;

import gpu;
import sample_args;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;

const char[*] BUILD_SPIRV = $embed("shaders/build_draws.comp.spv");
const char[*] VERT_SPIRV  = $embed("shaders/gpu_driven.vert.spv");
const char[*] FRAG_SPIRV  = $embed("shaders/gpu_driven.frag.spv");

const uint GRID = 16;
const uint INSTANCES = GRID * GRID;
const usz INSTANCE_UPLOAD_BYTES = INSTANCES * Instance::size;
const usz CORNER_UPLOAD_BYTES = 4 * 8;
const usz INDEX_UPLOAD_BYTES = 6 * uint::size;
const usz ARGS_UPLOAD_OFFSET =
    ((INSTANCE_UPLOAD_BYTES + CORNER_UPLOAD_BYTES + INDEX_UPLOAD_BYTES + 15) / 16) * 16;
const usz ARGS_UPLOAD_BYTES = INSTANCES * gpu::DrawIndexedIndirectCommand::size;
const usz COUNT_UPLOAD_OFFSET = ((ARGS_UPLOAD_OFFSET + ARGS_UPLOAD_BYTES + 3) / 4) * 4;
const usz BUILD_ROOT_UPLOAD_OFFSET = ((COUNT_UPLOAD_OFFSET + uint::size + 15) / 16) * 16;
const usz DRAW_ROOT_UPLOAD_OFFSET = ((BUILD_ROOT_UPLOAD_OFFSET + BuildRoot::size + 15) / 16) * 16;
const usz UPLOAD_BYTES_PER_SLOT = DRAW_ROOT_UPLOAD_OFFSET + DrawRoot::size;
$assert UPLOAD_BYTES_PER_SLOT == 13456;

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("gpu_driven_draw_sdl: FAIL (%s)", err);
        return 1;
    }
    io::printn("gpu_driven_draw_sdl: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l gpu-driven draws", 800, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::RuntimeDesc runtime_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "gpu_driven_draw_sdl",
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
            slot_capacity: UPLOAD_BYTES_PER_SLOT,
            access:        upload_access,
            debug_name:    "gpu_driven_frame_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

    gpu::DeviceCaps caps = gpu::get_device_caps(&device)!;
    bool use_count = caps.draw_indirect_count;
    io::printfn("gpu_driven_draw_sdl: indirect-count path %s", use_count ? "on" : "off");

    uint width;
    uint height;
    sample_window::pixel_size(&window, &width, &height);
    gpu::SwapchainDesc swapchain_desc = {
        .width        = width,
        .height       = height,
        .preferred_format = gpu::Format.BGRA8_UNORM,
        .present_mode = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX,
        .srgb         = false,
        .debug_name   = "gpu_driven_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)gpu::destroy_swapchain(&device, swapchain);

    gpu::ShaderDesc build_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = BUILD_SPIRV[..], .entry_point = "main", .debug_name = "build_draws" };
    gpu::ShaderCode build_shader = gpu::prepare_shader_code(&build_sd)!;
    gpu::ComputePipelineDesc build_desc = { .shader = build_shader, .push_constant_size = gpu::RootPush::size, .debug_name = "build_draws" };
    gpu::PipelineHandle build_pipeline = gpu::create_compute_pipeline(&device, &build_desc)!;
    defer (void)gpu::destroy_pipeline(&device, build_pipeline);

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = VERT_SPIRV[..], .entry_point = "main", .debug_name = "gpu_driven_vert" };
    gpu::ShaderCode vert = gpu::prepare_shader_code(&vert_sd)!;
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = FRAG_SPIRV[..], .entry_point = "main", .debug_name = "gpu_driven_frag" };
    gpu::ShaderCode frag = gpu::prepare_shader_code(&frag_sd)!;

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .color_formats   = color_formats[..],
        .debug_name      = "gpu_driven_draw",
    };
    gpu::PipelineHandle pipeline;
    bool pipeline_valid = false;
    if (!swapchain_info.dormant) {
        pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
        pipeline_valid = true;
    }
    defer {
        if (pipeline_valid) (void)gpu::destroy_pipeline(&device, pipeline);
    }
    long frame = 0;
    bool running = true;
    gpu::CompletionPoint last_graphics;
    defer {
        if (last_graphics.is_valid()) {
            (void)gpu::wait_completion(last_graphics, ulong::max);
        }
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
        if (!pipeline_valid || color_formats[0] != swapchain_info.format) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
            if (pipeline_valid) gpu::destroy_pipeline(&device, pipeline)!;
            pipeline_valid = false;
            color_formats[0] = swapchain_info.format;
            pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
            pipeline_valid = true;
        }

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(&device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            continue;
        }

        sample_frame_upload::FrameUploadBatch upload_batch =
            sample_frame_upload::begin_frame_upload(&upload_ring)!;
        defer catch {
            if (upload_batch.ring != null) {
                (void)sample_frame_upload::cancel_frame_upload(&upload_batch);
            }
        };

        float time = (float)frame / 60.0f;

        gpu::GpuSpan instances_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      INSTANCES * Instance::size,
            alignment: 16,
        )!;
        Instance* instances = (Instance*)gpu::get_span_mapping(&device, instances_span)!.ptr;
        for (uint y = 0; y < GRID; y++) {
            for (uint x = 0; x < GRID; x++) {
                uint i = y * GRID + x;
                float fx = ((float)x + 0.5f) / GRID * 2.0f - 1.0f;
                float fy = ((float)y + 0.5f) / GRID * 2.0f - 1.0f;
                instances[i] = {
                    .pos   = { fx, fy },
                    .scale = 0.04f,
                    .color = { (float)x / GRID, (float)y / GRID, 1.0f - (float)x / GRID, 1.0f },
                };
            }
        }
        gpu::GpuAddress instances_address = gpu::get_span_address(&device, instances_span)!;

        gpu::GpuSpan corners_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      4 * 8,
            alignment: 16,
        )!;
        float* corners = (float*)gpu::get_span_mapping(&device, corners_span)!.ptr;
        float[8] corner_data = { -1.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f, 1.0f, 1.0f };
        for (uint i = 0; i < 8; i++) corners[i] = corner_data[i];
        gpu::GpuAddress corners_address = gpu::get_span_address(&device, corners_span)!;

        gpu::GpuSpan index_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      6 * 4,
            alignment: 4,
        )!;
        uint* indices = (uint*)gpu::get_span_mapping(&device, index_span)!.ptr;
        uint[6] index_data = { 0, 1, 2, 2, 1, 3 };
        for (uint i = 0; i < 6; i++) indices[i] = index_data[i];

        gpu::GpuSpan args_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      INSTANCES * gpu::DrawIndexedIndirectCommand::size,
            alignment: 16,
        )!;
        gpu::GpuAddress args_address = gpu::get_span_address(&device, args_span)!;
        gpu::GpuSpan count_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      4,
            alignment: 4,
        )!;
        gpu::GpuAddress count_address = gpu::get_span_address(&device, count_span)!;

        gpu::GpuSpan build_root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      BuildRoot::size,
            alignment: 16,
        )!;
        BuildRoot* build_root = (BuildRoot*)gpu::get_span_mapping(&device, build_root_span)!.ptr;
        build_root.instances_gpu  = instances_address;
        build_root.args_gpu       = args_address;
        build_root.count_gpu      = count_address;
        build_root.instance_count = INSTANCES;
        build_root.time           = time;
        gpu::GpuAddress build_root_address = gpu::get_span_address(&device, build_root_span)!;

        gpu::GpuSpan draw_root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      DrawRoot::size,
            alignment: 16,
        )!;
        DrawRoot* draw_root = (DrawRoot*)gpu::get_span_mapping(&device, draw_root_span)!.ptr;
        draw_root.corners_gpu   = corners_address;
        draw_root.instances_gpu = instances_address;
        gpu::GpuAddress draw_root_address = gpu::get_span_address(&device, draw_root_span)!;

        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
        defer (void)gpu::discard_commands(&cmd);

        gpu::cmd_dispatch(
            commands: &cmd,
            pipeline: build_pipeline,
            root:     build_root_address,
            groups:   { (INSTANCES + BUILD_WORKGROUP - 1) / BUILD_WORKGROUP, 1, 1 },
        )!;

        gpu::GlobalBarrier indirect_ready = {
            .before_stage  = gpu::Stage.COMPUTE_SHADER,
            .after_stage   = gpu::Stage.INDIRECT_COMMAND,
            .before_hazard = gpu::Hazard.SHADER_WRITE,
            .after_hazard  = gpu::Hazard.INDIRECT_READ,
        };
        gpu::cmd_global_barrier(&cmd, &indirect_ready)!;

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
            .texture = acquired.texture,
            .load_op = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear = { .rgba = { 0.03f, 0.03f, 0.08f, 1.0f } },
        }};
        gpu::RenderPassDesc pass = {
            .colors = colors[..],
            .width  = swapchain_info.width,
            .height = swapchain_info.height,
        };
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        if (use_count) {
            gpu::cmd_draw_indexed_indirect_count(
                commands:       &cmd,
                pipeline:       pipeline,
                vertex_root:    draw_root_address,
                fragment_root:  (gpu::GpuAddress)0,
                args:           args_span,
                count_span:     count_span,
                max_draw_count: INSTANCES,
                index_span:     index_span,
            )!;
        } else {
            gpu::cmd_draw_indexed_indirect(
                commands:      &cmd,
                pipeline:      pipeline,
                vertex_root:   draw_root_address,
                fragment_root: (gpu::GpuAddress)0,
                args:          args_span,
                draw_count:    INSTANCES,
                index_span:    index_span,
            )!;
        }
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

        sample_frame_upload::flush_frame_upload(&upload_batch)!;
        gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
        defer (void)gpu::discard_executable_commands(&lists[0]);
        gpu::SubmitDesc submit = {
            .command_lists = lists[..],
            .readiness     = acquired.readiness,
        };
        last_graphics = gpu::submit(graphics_queue, &submit)!;
        sample_frame_upload::retire_frame_upload(&upload_batch, last_graphics)!;

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                device:              &device,
                producer_completion: last_graphics,
                queue_kind:          gpu::QueueKind.GRAPHICS,
                src:                 acquired.texture,
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

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

}
