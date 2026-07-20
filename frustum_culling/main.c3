module frustum_culling;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;
import std::math;

const char[*] CULL_SPIRV = $embed("shaders/cull.comp.spv");
const char[*] VERT_SPIRV = $embed("shaders/scene.vert.spv");
const char[*] FRAG_SPIRV = $embed("shaders/scene.frag.spv");

const uint GRID = 16;
const float GRID_SPACING = 1.6f;
const float CUBE_HALF = 0.35f;
const uint CUBE_VERTEX_COUNT = 36;
const usz  ARGS_BYTES = INSTANCE_COUNT * 16;
const long STATS_SAMPLE_INTERVAL = 10;
const usz UPLOAD_BYTES_PER_SLOT = CullRoot::size + SceneDrawRoot::size;

struct CubeFace {
    float[<3>] normal;
    float[<3>] u_axis;
    float[<3>] v_axis;
    float      lambert;
}

const CubeFace[6] CUBE_FACES = {
    { { 0, 0, 1 },  { 1, 0, 0 },  { 0, 1, 0 }, 1.00f },
    { { 0, 0, -1 }, { -1, 0, 0 }, { 0, 1, 0 }, 0.55f },
    { { 1, 0, 0 },  { 0, 0, -1 }, { 0, 1, 0 }, 0.80f },
    { { -1, 0, 0 }, { 0, 0, 1 },  { 0, 1, 0 }, 0.65f },
    { { 0, 1, 0 },  { 1, 0, 0 },  { 0, 0, -1 }, 0.90f },
    { { 0, -1, 0 }, { 1, 0, 0 },  { 0, 0, 1 }, 0.45f },
};

<* One vec4 per vertex: unit-cube position.xyz + face lambert. *>
fn void write_cube_vertices(float* out) {
    float[<2>][6] corners = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 0 }, { 1, 1 }, { 0, 1 } };
    usz cursor = 0;
    foreach (&face : CUBE_FACES) {
        for (uint i = 0; i < 6; i++) {
            float cu = corners[i][0] * 2.0f - 1.0f;
            float cv = corners[i][1] * 2.0f - 1.0f;
            float[<3>] pos = face.normal + face.u_axis * cu + face.v_axis * cv;
            out[cursor++] = pos[0];
            out[cursor++] = pos[1];
            out[cursor++] = pos[2];
            out[cursor++] = face.lambert;
        }
    }
}

fn void seed_instances(float* out) {
    float radius = CUBE_HALF * 1.7320508f;
    float offset = (GRID - 1) * GRID_SPACING * 0.5f;
    for (uint i = 0; i < INSTANCE_COUNT; i++) {
        uint x = i % GRID;
        uint y = (i / GRID) % GRID;
        uint z = i / (GRID * GRID);
        usz base = (usz)i * 8;
        out[base]     = (float)x * GRID_SPACING - offset;
        out[base + 1] = (float)y * GRID_SPACING - offset;
        out[base + 2] = (float)z * GRID_SPACING - offset;
        out[base + 3] = radius;
        out[base + 4] = 0.25f + 0.75f * (float)x / GRID;
        out[base + 5] = 0.25f + 0.75f * (float)y / GRID;
        out[base + 6] = 0.25f + 0.75f * (float)z / GRID;
        out[base + 7] = 1.0f;
    }
}

<* Gribb-Hartmann: frustum planes from column-major view-projection rows,
   normalized so plane.w distances are in world units. *>
fn void extract_planes(gpu::Vec4f* planes, sample_camera::Mat4 m) {
    float[<4>][4] rows;
    for (uint r = 0; r < 4; r++) {
        rows[r] = { m[r], m[4 + r], m[8 + r], m[12 + r] };
    }
    float[<4>][6] raw = {
        rows[3] + rows[0],
        rows[3] - rows[0],
        rows[3] + rows[1],
        rows[3] - rows[1],
        rows[2],
        rows[3] - rows[2],
    };
    for (uint i = 0; i < 6; i++) {
        float[<4>] p = raw[i];
        float len = math::sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
        p = p / len;
        planes[i] = { p[0], p[1], p[2], p[3] };
    }
}

fn gpu::TextureUse? swapchain_texture_use(gpu::TextureUse use) {
    switch (use) {
        case gpu::TextureUse.UNDEFINED: return gpu::TextureUse.UNDEFINED;
        case gpu::TextureUse.PRESENT:   return gpu::TextureUse.PRESENT;
        default:                           return gpu::INVALID_RESOURCE_STATE~;
    }
}

fn gpu::TextureHandle? create_depth_texture(gpu::Device* device, uint width, uint height) {
    gpu::TextureDesc desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = width,
        .height     = height,
        .format     = gpu::Format.D32_FLOAT,
        .usage      = { .depth_attach },
        .access     = { .graphics },
        .debug_name = "culling_depth",
    };
    return gpu::create_texture(device, &desc);
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("frustum_culling: FAIL (%s)", err);
        return 1;
    }
    io::printn("frustum_culling: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l frustum culling", 1024, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::RuntimeDesc runtime_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "frustum_culling",
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
            debug_name:    "frustum_root_upload",
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
        .debug_name       = "culling_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)gpu::destroy_swapchain(&device, swapchain);

    gpu::TextureHandle depth;
    uint depth_width;
    uint depth_height;
    bool depth_valid = false;
    if (!swapchain_info.dormant) {
        depth = create_depth_texture(&device, swapchain_info.width, swapchain_info.height)!;
        depth_width = swapchain_info.width;
        depth_height = swapchain_info.height;
        depth_valid = true;
    }
    defer {
        if (depth_valid) (void)gpu::destroy_texture(&device, depth);
    }

    gpu::AllocationDesc vertex_desc = {
        .size         = CUBE_VERTEX_COUNT * 16,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "cube_vertices",
    };
    gpu::GpuAllocation vertex_allocation = gpu::allocate_memory(&device, &vertex_desc)!;
    defer (void)gpu::free_allocation(&device, &vertex_allocation);
    gpu::GpuSpan vertex_span = gpu::get_allocation_span(&device, vertex_allocation)!;
    write_cube_vertices((float*)gpu::get_span_mapping(&device, vertex_span)!.ptr);
    gpu::flush_mapped_span(&device, vertex_span)!;
    gpu::GpuAddress vertex_address = gpu::get_span_address(&device, vertex_span)!;

    gpu::AllocationDesc instances_desc = {
        .size         = INSTANCE_COUNT * 32,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "instances",
    };
    gpu::GpuAllocation instances_allocation = gpu::allocate_memory(&device, &instances_desc)!;
    defer (void)gpu::free_allocation(&device, &instances_allocation);
    gpu::GpuSpan instances_span = gpu::get_allocation_span(&device, instances_allocation)!;
    seed_instances((float*)gpu::get_span_mapping(&device, instances_span)!.ptr);
    gpu::flush_mapped_span(&device, instances_span)!;
    gpu::GpuAddress instances_address = gpu::get_span_address(&device, instances_span)!;

    gpu::AllocationDesc args_desc = {
        .size         = ARGS_BYTES,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "draw_args",
    };
    gpu::GpuAllocation args_allocation = gpu::allocate_memory(&device, &args_desc)!;
    defer (void)gpu::free_allocation(&device, &args_allocation);
    gpu::GpuSpan args_span = gpu::get_allocation_span(&device, args_allocation)!;
    gpu::GpuAddress args_address = gpu::get_span_address(&device, args_span)!;

    gpu::AllocationDesc stats_desc = {
        .size         = 4,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "cull_stats",
    };
    gpu::GpuAllocation stats_allocation = gpu::allocate_memory(&device, &stats_desc)!;
    defer (void)gpu::free_allocation(&device, &stats_allocation);
    gpu::GpuSpan stats_span = gpu::get_allocation_span(&device, stats_allocation)!;
    uint* visible_count = (uint*)gpu::get_span_mapping(&device, stats_span)!.ptr;
    gpu::GpuAddress stats_address = gpu::get_span_address(&device, stats_span)!;

    gpu::ShaderDesc cull_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = CULL_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode cull_shader = gpu::prepare_shader_code(&cull_sd)!;
    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode vert = gpu::prepare_shader_code(&vert_sd)!;
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode frag = gpu::prepare_shader_code(&frag_sd)!;

    gpu::ComputePipelineDesc cull_pd = { .shader = cull_shader, .push_constant_size = gpu::RootPush::size, .debug_name = "cull" };
    gpu::PipelineHandle cull_pipe = gpu::create_compute_pipeline(&device, &cull_pd)!;
    defer (void)gpu::destroy_pipeline(&device, cull_pipe);

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc scene_pd = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .color_formats   = color_formats[..],
        .depth_format    = gpu::Format.D32_FLOAT,
        .debug_name      = "culled_scene",
    };
    gpu::PipelineHandle scene_pipe;
    bool scene_pipe_valid = false;
    if (!swapchain_info.dormant) {
        scene_pipe = gpu::create_graphics_pipeline(&device, &scene_pd)!;
        scene_pipe_valid = true;
    }
    defer {
        if (scene_pipe_valid) (void)gpu::destroy_pipeline(&device, scene_pipe);
    }

    sample_camera::OrbitCamera camera = { .pitch = 0.45f, .radius = 19.0f, .target = { 0, 0, 0 } };

    uint min_visible = INSTANCE_COUNT + 1;
    uint max_visible = 0;
    bool depth_fresh = true;
    long frame = 0;
    bool running = true;
    gpu::CompletionPoint last_graphics;
    defer {
        if (last_graphics.is_valid()) (void)gpu::wait_completion(last_graphics, ulong::max);
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

        bool pipeline_changed = !scene_pipe_valid || color_formats[0] != swapchain_info.format;
        bool depth_changed = !depth_valid
            || depth_width != swapchain_info.width
            || depth_height != swapchain_info.height;
        if (pipeline_changed || depth_changed) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
        }
        if (pipeline_changed) {
            if (scene_pipe_valid) gpu::destroy_pipeline(&device, scene_pipe)!;
            scene_pipe_valid = false;
            color_formats[0] = swapchain_info.format;
            scene_pipe = gpu::create_graphics_pipeline(&device, &scene_pd)!;
            scene_pipe_valid = true;
        }
        if (depth_changed) {
            if (depth_valid) gpu::destroy_texture(&device, depth)!;
            depth_valid = false;
            depth = create_depth_texture(&device, swapchain_info.width, swapchain_info.height)!;
            depth_width = swapchain_info.width;
            depth_height = swapchain_info.height;
            depth_valid = true;
            depth_fresh = true;
        }
        width = swapchain_info.width;
        height = swapchain_info.height;

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

        bool sample_stats = frame % STATS_SAMPLE_INTERVAL == 0;

        camera.yaw = (float)frame * 0.05f;
        sample_camera::Mat4 view_proj = sample_camera::mul(
            sample_camera::perspective(0.9f, (float)width / (float)height, 0.1f, 100.0f),
            camera.view());

        gpu::GpuSpan cull_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      CullRoot::size,
            alignment: 16,
        )!;
        CullRoot* cull_root = (CullRoot*)gpu::get_span_mapping(&device, cull_span)!.ptr;
        extract_planes(&cull_root.plane0, view_proj);
        cull_root.instances_gpu = instances_address;
        cull_root.args_gpu      = args_address;
        cull_root.stats_gpu     = stats_address;
        cull_root.count         = INSTANCE_COUNT;
        gpu::GpuAddress cull_root_address = gpu::get_span_address(&device, cull_span)!;

        gpu::GpuSpan draw_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      SceneDrawRoot::size,
            alignment: 16,
        )!;
        SceneDrawRoot* draw_root = (SceneDrawRoot*)gpu::get_span_mapping(&device, draw_span)!.ptr;
        for (uint c = 0; c < 4; c++) {
            gpu::Vec4f* cols = &draw_root.view_proj_c0;
            cols[c] = { view_proj[c * 4], view_proj[c * 4 + 1], view_proj[c * 4 + 2], view_proj[c * 4 + 3] };
        }
        draw_root.instances_gpu = instances_address;
        draw_root.vertex_gpu    = vertex_address;
        gpu::GpuAddress draw_root_address = gpu::get_span_address(&device, draw_span)!;
        sample_frame_upload::flush_frame_upload(&upload_batch)!;

        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
        defer (void)gpu::discard_commands(&cmd);

        if (depth_fresh) {
            gpu::TextureBarrier depth_init = {
                .texture       = depth,
                .before        = gpu::TextureUse.UNDEFINED,
                .after         = gpu::TextureUse.DEPTH_ATTACHMENT,
            };
            gpu::cmd_texture_barrier(&cmd, &depth_init)!;
            depth_fresh = false;
        }

        if (sample_stats) {
            // The cull shader increments the visible counter every frame, so a
            // host reset would race with the previous submission. Zero it on
            // the GPU instead: the
            // first barrier orders the fill after all prior compute writes, the
            // second makes the zero visible to this frame's dispatch.
            gpu::Barrier stats_before_clear = {
                .before = { .compute = true },
                .after = { .transfer = true },
            };
            gpu::cmd_barrier(&cmd, &stats_before_clear)!;
            gpu::cmd_fill_buffer(&cmd, stats_span, 0)!;
            gpu::Barrier stats_after_clear = {
                .before = { .transfer = true },
                .after = { .compute = true },
            };
            gpu::cmd_barrier(&cmd, &stats_after_clear)!;
        }

        gpu::cmd_bind_pipeline(&cmd, cull_pipe)!;
        gpu::cmd_dispatch(
            commands: &cmd,
            root:     cull_root_address,
            groups:   { (INSTANCE_COUNT + CULL_TILE - 1) / CULL_TILE, 1, 1 },
        )!;

        gpu::Barrier args_ready = {
            .before = { .compute = true },
            .after = { .compute = true },
            .hazards = { .draw_arguments = true },
        };
        gpu::cmd_barrier(&cmd, &args_ready)!;
        if (sample_stats) {
            gpu::Barrier stats_ready = {
                .before = { .compute = true },
                .after = { .host = true },
            };
            gpu::cmd_barrier(&cmd, &stats_ready)!;
        }

        gpu::TextureBarrier to_attach = gpu::texture_transition(
            texture: acquired.texture,
            before:  swapchain_texture_use(acquired.prior_use)!,
            after:   gpu::TextureUse.COLOR_ATTACHMENT,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_attach)!;

        gpu::ColorTargetDesc[1] colors = {{
            .texture  = acquired.texture,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.05f, 0.06f, 0.10f, 1.0f } },
        }};
        gpu::DepthTargetDesc depth_target = {
            .texture  = depth,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc pass = { .colors = colors[..], .depth = &depth_target, .width = width, .height = height };
        gpu::cmd_bind_pipeline(&cmd, scene_pipe)!;
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::DepthState depth_state = {
            .test_enable  = true,
            .write_enable = true,
            .compare      = gpu::CompareOp.LESS,
        };
        gpu::cmd_set_depth_state(&cmd, &depth_state)!;
        gpu::cmd_draw_indirect(
            commands:      &cmd,
            vertex_root:   draw_root_address,
            fragment_root: draw_root_address,
            args:          args_span,
            draw_count:    INSTANCE_COUNT,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = gpu::texture_transition(
            texture: acquired.texture,
            before:  gpu::TextureUse.COLOR_ATTACHMENT,
            after:   gpu::TextureUse.PRESENT,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_present)!;
        gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
        defer (void)gpu::discard_executable_commands(&lists[0]);
        gpu::SubmitDesc submit = {
            .command_lists = lists[..],
            .readiness     = acquired.readiness,
        };
        last_graphics = gpu::submit(graphics_queue, &submit)!;
        sample_frame_upload::retire_frame_upload(&upload_batch, last_graphics)!;

        if (sample_stats) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
            gpu::invalidate_mapped_span(&device, stats_span)!;
            uint visible = *visible_count;
            io::printfn("frame %d: visible %d / %d", frame, visible, INSTANCE_COUNT);
            if (visible < min_visible) min_visible = visible;
            if (visible > max_visible) max_visible = visible;
        }

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                device:              &device,
                producer_completion: last_graphics,
                queue_kind:          gpu::QueueKind.GRAPHICS,
                src:         acquired.texture,
                width:       width,
                height:      height,
                format:      swapchain_info.format,
                from_use:    gpu::TextureUse.PRESENT,
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

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;

    if (max_visible == 0 || max_visible > INSTANCE_COUNT) return gpu::INVALID_RESOURCE_STATE~;
    if (min_visible >= max_visible) {
        io::printfn("culling never varied: min %d max %d", min_visible, max_visible);
        return gpu::INVALID_RESOURCE_STATE~;
    }
    io::printfn("visible range over run: %d..%d of %d", min_visible, max_visible, INSTANCE_COUNT);
}
