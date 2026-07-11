module textured_cube;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_window;
import std::io;
import std::math;

const char[*] CUBE_VERT_SPIRV = $embed("shaders/cube.vert.spv");
const char[*] CUBE_FRAG_SPIRV = $embed("shaders/cube.frag.spv");

const uint TEX_SIZE = 16;

const uint CUBE_VERTEX_COUNT = 36;
const usz  CUBE_VERTEX_BYTES = CUBE_VERTEX_COUNT * 32;

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

<* Two vec4s per vertex: position.xyz + face lambert, uv.xy + padding. *>
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
            out[cursor++] = corners[i][0];
            out[cursor++] = corners[i][1];
            out[cursor++] = 0.0f;
            out[cursor++] = 0.0f;
        }
    }
}

fn void write_matrix(gpu::Vec4f* columns, sample_camera::Mat4 m) {
    for (uint c = 0; c < 4; c++) {
        columns[c] = { m[c * 4], m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3] };
    }
}

fn sample_camera::Mat4 spin_model(float time) {
    float a = time * 0.9f;
    float b = time * 0.6f;
    sample_camera::Mat4 yaw_m = {
        math::cos(a), 0, -math::sin(a), 0,
        0, 1, 0, 0,
        math::sin(a), 0, math::cos(a), 0,
        0, 0, 0, 1,
    };
    sample_camera::Mat4 pitch_m = {
        1, 0, 0, 0,
        0, math::cos(b), math::sin(b), 0,
        0, -math::sin(b), math::cos(b), 0,
        0, 0, 0, 1,
    };
    return sample_camera::mul(yaw_m, pitch_m);
}

fn gpu::TextureHandle? create_depth_texture(gpu::Device* device, uint width, uint height) {
    gpu::TextureDesc desc = {
        .dimension = gpu::TextureDimension.TEX_2D,
        .width     = width,
        .height    = height,
        .format    = gpu::Format.D32_FLOAT,
        .usage     = { .depth_attach },
        .debug_name = "cube_depth",
    };
    return gpu::create_texture(device, &desc);
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("textured_cube: FAIL (%s)", err);
        return 1;
    }
    io::printn("textured_cube: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l textured cube", 800, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::DeviceDesc device_desc = {
        .backend             = gpu::BackendKind.VULKAN,
        .enable_validation   = true,
        .enable_presentation = true,
        .frames_in_flight    = 2,
        .application_name    = "textured_cube",
    };
    gpu::Device device = gpu::create_device(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    gpu::SurfaceDesc surface = sample_window::surface_desc_for(&window)!;
    uint width;
    uint height;
    sample_window::pixel_size(&window, &width, &height);
    gpu::SwapchainDesc swapchain_desc = {
        .width            = width,
        .height           = height,
        .preferred_format = gpu::Format.BGRA8_UNORM,
        .present_mode     = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX,
        .srgb             = false,
        .debug_name       = "cube_swapchain",
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
        .size        = CUBE_VERTEX_BYTES,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = "cube_vertices",
    };
    gpu::BufferHandle vertices = gpu::create_buffer(&device, &vertex_desc)!;
    defer (void)gpu::destroy_buffer(&device, vertices);
    gpu::GpuSpan vertex_span = gpu::get_buffer_span(&device, vertices)!;
    write_cube_vertices((float*)vertex_span.cpu);
    gpu::flush_buffer(&device, vertices, 0, 0)!;

    gpu::TextureDesc tex_desc = {
        .dimension = gpu::TextureDimension.TEX_2D,
        .width     = TEX_SIZE,
        .height    = TEX_SIZE,
        .format    = gpu::Format.RGBA8_UNORM,
        .usage     = { .sampled, .transfer_dst },
    };
    gpu::TextureHandle checker = gpu::create_texture(&device, &tex_desc)!;
    defer (void)gpu::destroy_texture(&device, checker);
    gpu::TextureIndex tex_index = gpu::create_texture_descriptor(&device, checker, null)!;
    defer (void)gpu::destroy_texture_descriptor(&device, tex_index);

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex smp_index = gpu::create_sampler(&device, &sampler_desc)!;
    defer (void)gpu::destroy_sampler(&device, smp_index);

    gpu::BufferDesc staging_desc = {
        .size = TEX_SIZE * TEX_SIZE * 4, .usage = { .transfer_src }, .memory_kind = gpu::MemoryKind.STAGING,
    };
    gpu::BufferHandle staging = gpu::create_buffer(&device, &staging_desc)!;
    defer (void)gpu::destroy_buffer(&device, staging);
    gpu::GpuSpan staging_span = gpu::get_buffer_span(&device, staging)!;
    char* texels = (char*)staging_span.cpu;
    for (uint y = 0; y < TEX_SIZE; y++) {
        for (uint x = 0; x < TEX_SIZE; x++) {
            bool checkered = ((x / 4) + (y / 4)) % 2 == 0;
            char* texel = &texels[(y * TEX_SIZE + x) * 4];
            texel[0] = checkered ? (char)235 : (char)30;
            texel[1] = checkered ? (char)235 : (char)30;
            texel[2] = checkered ? (char)235 : (char)45;
            texel[3] = (char)255;
        }
    }
    gpu::flush_buffer(&device, staging, 0, 0)!;

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = CUBE_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle vert = gpu::create_shader(&device, &vert_sd)!;
    defer (void)gpu::destroy_shader(&device, vert);
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = CUBE_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle frag = gpu::create_shader(&device, &frag_sd)!;
    defer (void)gpu::destroy_shader(&device, frag);

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .depth           = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.LESS },
        .color_formats   = color_formats[..],
        .depth_format    = gpu::Format.D32_FLOAT,
        .debug_name      = "textured_cube",
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

    sample_camera::OrbitCamera camera = { .pitch = 0.45f, .radius = 5.5f, .target = { 0, 0, 0 } };

    bool checker_uploaded = false;
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

        bool pipeline_changed = !pipeline_valid || color_formats[0] != swapchain_info.format;
        bool depth_changed = !depth_valid
            || depth_width != swapchain_info.width
            || depth_height != swapchain_info.height;
        if (pipeline_changed || depth_changed) {
            gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
        }
        if (pipeline_changed) {
            if (pipeline_valid) gpu::destroy_pipeline(&device, pipeline)!;
            pipeline_valid = false;
            color_formats[0] = swapchain_info.format;
            pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
            pipeline_valid = true;
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

        gpu::FrameToken frame_token = gpu::begin_frame(&device)!;

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(&device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            gpu::end_frame(&frame_token)!;
            continue;
        }

        gpu::CommandList cmd = gpu::begin_commands(&device, gpu::QueueKind.GRAPHICS)!;

        if (!checker_uploaded) {
            gpu::TextureBarrier to_dst = {
                .texture       = checker,
                .before_stage  = gpu::Stage.HOST,
                .after_stage   = gpu::Stage.TRANSFER,
                .before_hazard = gpu::Hazard.HOST_WRITE,
                .after_hazard  = gpu::Hazard.TRANSFER_WRITE,
                .old_layout    = gpu::TextureLayout.UNDEFINED,
                .new_layout    = gpu::TextureLayout.TRANSFER_DST,
            };
            gpu::cmd_texture_barrier(&cmd, &to_dst)!;
            gpu::BufferTextureCopyDesc upload = { .src = staging_span, .texture = checker };
            gpu::cmd_copy_buffer_to_texture(&cmd, &upload)!;
            gpu::TextureBarrier to_read = {
                .texture       = checker,
                .before_stage  = gpu::Stage.TRANSFER,
                .after_stage   = gpu::Stage.FRAGMENT_SHADER,
                .before_hazard = gpu::Hazard.TRANSFER_WRITE,
                .after_hazard  = gpu::Hazard.SHADER_READ,
                .old_layout    = gpu::TextureLayout.TRANSFER_DST,
                .new_layout    = gpu::TextureLayout.SHADER_READ,
            };
            gpu::cmd_texture_barrier(&cmd, &to_read)!;
            checker_uploaded = true;
        }

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

        // The per-frame-data pattern: everything the shaders need this frame
        // is written into a fresh frame-arena span; nothing persists.
        float time = (float)frame / 60.0f;
        camera.yaw = time * 0.5f;
        sample_camera::Mat4 view_proj = sample_camera::mul(
            sample_camera::perspective(
                fov_y_radians: 1.1f,
                aspect:        (float)swapchain_info.width / (float)swapchain_info.height,
                near:          0.1f,
                far:           50.0f,
            ),
            camera.view());

        gpu::GpuSpan root_span = gpu::alloc_frame_span(&frame_token, SceneRoot::size, 16)!;
        SceneRoot* root = (SceneRoot*)root_span.cpu;
        write_matrix(&root.view_proj_c0, view_proj);
        write_matrix(&root.model_c0, spin_model(time));
        root.vertex_gpu     = vertex_span.gpu;
        root.albedo_texture = tex_index;
        root.albedo_sampler = smp_index;
        root.time           = time;

        gpu::ColorTargetDesc[1] colors = {{
            .texture  = acquired.texture,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.06f, 0.07f, 0.11f, 1.0f } },
        }};
        gpu::DepthTargetDesc depth_target = {
            .texture  = depth,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc pass = {
            .colors = colors[..],
            .depth  = &depth_target,
            .width  = swapchain_info.width,
            .height = swapchain_info.height,
        };
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::cmd_draw(
            commands:       &cmd,
            pipeline:       pipeline,
            vertex_root:    root_span.gpu,
            fragment_root:  root_span.gpu,
            vertex_count:   CUBE_VERTEX_COUNT,
            instance_count: 1,
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
        gpu::CommandList[1] lists = { cmd };
        gpu::SubmitDesc submit = { .command_lists = lists[..], .swapchain = swapchain };
        gpu::submit(&device, &submit)!;

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
}
