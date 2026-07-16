module frustum_culling;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
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

fn gpu::TextureUse? swapchain_texture_use(gpu::TextureLayout layout) {
    switch (layout) {
        case gpu::TextureLayout.UNDEFINED: return gpu::TextureUse.UNDEFINED;
        case gpu::TextureLayout.PRESENT:   return gpu::TextureUse.PRESENT;
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

    gpu::BufferDesc vertex_desc = {
        .size        = CUBE_VERTEX_COUNT * 16,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .access      = { .graphics },
        .debug_name  = "cube_vertices",
    };
    gpu::BufferHandle vertices = gpu::create_buffer(&device, &vertex_desc)!;
    defer (void)gpu::destroy_buffer(&device, vertices);
    gpu::GpuSpan vertex_span = gpu::get_buffer_span(&device, vertices)!;
    write_cube_vertices((float*)vertex_span.cpu);
    gpu::flush_buffer(&device, vertices, 0, 0)!;

    gpu::BufferDesc instances_desc = {
        .size        = INSTANCE_COUNT * 32,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .access      = { .graphics },
        .debug_name  = "instances",
    };
    gpu::BufferHandle instances = gpu::create_buffer(&device, &instances_desc)!;
    defer (void)gpu::destroy_buffer(&device, instances);
    gpu::GpuSpan instances_span = gpu::get_buffer_span(&device, instances)!;
    seed_instances((float*)instances_span.cpu);
    gpu::flush_buffer(&device, instances, 0, 0)!;

    gpu::BufferDesc args_desc = {
        .size        = ARGS_BYTES,
        .usage       = { .storage, .addressable, .indirect },
        .memory_kind = gpu::MemoryKind.DEVICE,
        .access      = { .graphics },
        .debug_name  = "draw_args",
    };
    gpu::BufferHandle args = gpu::create_buffer(&device, &args_desc)!;
    defer (void)gpu::destroy_buffer(&device, args);
    gpu::GpuSpan args_span = gpu::get_buffer_span(&device, args)!;

    gpu::BufferDesc stats_desc = {
        .size        = 4,
        .usage       = { .storage, .addressable, .transfer_dst },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .access      = { .graphics },
        .debug_name  = "cull_stats",
    };
    gpu::BufferHandle stats = gpu::create_buffer(&device, &stats_desc)!;
    defer (void)gpu::destroy_buffer(&device, stats);
    gpu::GpuSpan stats_span = gpu::get_buffer_span(&device, stats)!;
    uint* visible_count = (uint*)stats_span.cpu;

    gpu::ShaderDesc cull_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = CULL_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle cull_shader = gpu::create_shader(&device, &cull_sd)!;
    defer (void)gpu::destroy_shader(&device, cull_shader);
    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle vert = gpu::create_shader(&device, &vert_sd)!;
    defer (void)gpu::destroy_shader(&device, vert);
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle frag = gpu::create_shader(&device, &frag_sd)!;
    defer (void)gpu::destroy_shader(&device, frag);

    gpu::ComputePipelineDesc cull_pd = { .shader = cull_shader, .push_constant_size = gpu::RootPush::size, .debug_name = "cull" };
    gpu::PipelineHandle cull_pipe = gpu::create_compute_pipeline(&device, &cull_pd)!;
    defer (void)gpu::destroy_pipeline(&device, cull_pipe);

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc scene_pd = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .depth           = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.LESS },
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
            gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
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

        gpu::FrameToken frame_token = gpu::begin_frame(&device)!;

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(&device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            gpu::end_frame(&frame_token)!;
            continue;
        }

        bool sample_stats = frame % STATS_SAMPLE_INTERVAL == 0;

        camera.yaw = (float)frame * 0.05f;
        sample_camera::Mat4 view_proj = sample_camera::mul(
            sample_camera::perspective(0.9f, (float)width / (float)height, 0.1f, 100.0f),
            camera.view());

        gpu::GpuSpan cull_span = gpu::alloc_frame_span(&frame_token, CullRoot::size, 16)!;
        CullRoot* cull_root = (CullRoot*)cull_span.cpu;
        extract_planes(&cull_root.plane0, view_proj);
        cull_root.instances_gpu = instances_span.gpu;
        cull_root.args_gpu      = args_span.gpu;
        cull_root.stats_gpu     = stats_span.gpu;
        cull_root.count         = INSTANCE_COUNT;

        gpu::GpuSpan draw_span = gpu::alloc_frame_span(&frame_token, SceneDrawRoot::size, 16)!;
        SceneDrawRoot* draw_root = (SceneDrawRoot*)draw_span.cpu;
        for (uint c = 0; c < 4; c++) {
            gpu::Vec4f* cols = &draw_root.view_proj_c0;
            cols[c] = { view_proj[c * 4], view_proj[c * 4 + 1], view_proj[c * 4 + 2], view_proj[c * 4 + 3] };
        }
        draw_root.instances_gpu = instances_span.gpu;
        draw_root.vertex_gpu    = vertex_span.gpu;

        gpu::CommandList cmd = gpu::begin_commands(&device, gpu::QueueKind.GRAPHICS)!;

        if (depth_fresh) {
            gpu::TextureBarrier depth_init = {
                .texture       = depth,
                .before_stage  = gpu::Stage.HOST,
                .after_stage   = gpu::Stage.DEPTH_STENCIL,
                .before_hazard = gpu::Hazard.HOST_WRITE,
                .after_hazard  = gpu::Hazard.DEPTH_WRITE,
                .old_layout    = gpu::TextureLayout.UNDEFINED,
                .new_layout    = gpu::TextureLayout.DEPTH_STENCIL,
            };
            gpu::cmd_texture_barrier(&cmd, &depth_init)!;
            depth_fresh = false;
        }

        if (sample_stats) {
            // The cull shader increments the visible counter every frame, so a
            // host reset would race with the previous frame's still-in-flight
            // dispatch (frames_in_flight=2). Zero it on the GPU instead: the
            // first barrier orders the fill after all prior compute writes, the
            // second makes the zero visible to this frame's dispatch.
            gpu::BufferBarrier stats_before_clear = {
                .buffer = stats, .offset = 0, .size = 4,
                .before_stage = gpu::Stage.COMPUTE_SHADER, .after_stage = gpu::Stage.TRANSFER,
                .before_hazard = gpu::Hazard.SHADER_WRITE, .after_hazard = gpu::Hazard.TRANSFER_WRITE,
            };
            gpu::cmd_buffer_barrier(&cmd, &stats_before_clear)!;
            gpu::cmd_fill_buffer(&cmd, stats, 0, 4, 0)!;
            gpu::BufferBarrier stats_after_clear = {
                .buffer = stats, .offset = 0, .size = 4,
                .before_stage = gpu::Stage.TRANSFER, .after_stage = gpu::Stage.COMPUTE_SHADER,
                .before_hazard = gpu::Hazard.TRANSFER_WRITE, .after_hazard = gpu::Hazard.SHADER_WRITE,
            };
            gpu::cmd_buffer_barrier(&cmd, &stats_after_clear)!;
        }

        gpu::cmd_dispatch(
            commands: &cmd,
            pipeline: cull_pipe,
            root:     cull_span.gpu,
            groups:   { (INSTANCE_COUNT + CULL_TILE - 1) / CULL_TILE, 1, 1 },
        )!;

        gpu::BufferBarrier args_ready = {
            .buffer = args, .offset = 0, .size = ARGS_BYTES,
            .before_stage = gpu::Stage.COMPUTE_SHADER, .after_stage = gpu::Stage.INDIRECT_COMMAND,
            .before_hazard = gpu::Hazard.SHADER_WRITE, .after_hazard = gpu::Hazard.INDIRECT_READ,
        };
        gpu::cmd_buffer_barrier(&cmd, &args_ready)!;
        if (sample_stats) {
            gpu::BufferBarrier stats_ready = {
                .buffer = stats, .offset = 0, .size = 4,
                .before_stage = gpu::Stage.COMPUTE_SHADER, .after_stage = gpu::Stage.HOST,
                .before_hazard = gpu::Hazard.SHADER_WRITE, .after_hazard = gpu::Hazard.HOST_READ,
            };
            gpu::cmd_buffer_barrier(&cmd, &stats_ready)!;
        }

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
            .clear    = { .rgba = { 0.05f, 0.06f, 0.10f, 1.0f } },
        }};
        gpu::DepthTargetDesc depth_target = {
            .texture  = depth,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc pass = { .colors = colors[..], .depth = &depth_target, .width = width, .height = height };
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::cmd_draw_indirect(
            commands:      &cmd,
            pipeline:      scene_pipe,
            vertex_root:   draw_span.gpu,
            fragment_root: draw_span.gpu,
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
        gpu::end_commands(&cmd)!;

        gpu::CommandList[1] lists = { cmd };
        gpu::SubmitDesc submit = { .command_lists = lists[..], .swapchain = swapchain };
        gpu::submit(&device, &submit)!;

        if (sample_stats) {
            gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
            gpu::invalidate_buffer(&device, stats, 0, 0)!;
            uint visible = *visible_count;
            io::printfn("frame %d: visible %d / %d", frame, visible, INSTANCE_COUNT);
            if (visible < min_visible) min_visible = visible;
            if (visible > max_visible) max_visible = visible;
        }

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                device:      &device,
                src:         acquired.texture,
                width:       width,
                height:      height,
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

    if (max_visible == 0 || max_visible > INSTANCE_COUNT) return gpu::INVALID_RESOURCE_STATE~;
    if (min_visible >= max_visible) {
        io::printfn("culling never varied: min %d max %d", min_visible, max_visible);
        return gpu::INVALID_RESOURCE_STATE~;
    }
    io::printfn("visible range over run: %d..%d of %d", min_visible, max_visible, INSTANCE_COUNT);
}
