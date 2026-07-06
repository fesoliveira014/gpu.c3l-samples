module shadow_mapping;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_window;
import std::io;
import std::math;

const char[*] SHADOW_VERT_SPIRV = $embed("shaders/shadow.vert.spv");
const char[*] SHADOW_FRAG_SPIRV = $embed("shaders/shadow.frag.spv");
const char[*] SCENE_VERT_SPIRV  = $embed("shaders/scene.vert.spv");
const char[*] SCENE_FRAG_SPIRV  = $embed("shaders/scene.frag.spv");

const uint MAX_TRACKED_IMAGES = 8;
const uint CUBE_VERTEX_COUNT = 36;
const uint INSTANCE_COUNT = 9;
const float LIGHT_EXTENT = 14.0f;

struct CubeFace {
    float[<3>] normal;
    float[<3>] u_axis;
    float[<3>] v_axis;
    float      lambert;
}

const CubeFace[6] CUBE_FACES = {
    { { 0, 0, 1 },  { 1, 0, 0 },  { 0, 1, 0 }, 0.85f },
    { { 0, 0, -1 }, { -1, 0, 0 }, { 0, 1, 0 }, 0.55f },
    { { 1, 0, 0 },  { 0, 0, -1 }, { 0, 1, 0 }, 0.75f },
    { { -1, 0, 0 }, { 0, 0, 1 },  { 0, 1, 0 }, 0.65f },
    { { 0, 1, 0 },  { 1, 0, 0 },  { 0, 0, -1 }, 1.00f },
    { { 0, -1, 0 }, { 1, 0, 0 },  { 0, 0, 1 }, 0.40f },
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

<* Instance = three vec4s: center, per-axis scale, color. Slot 0 is the
   ground plane (wide flat cube); the rest are boxes of varied size. *>
fn void write_instances(float* out) {
    float[<3>][INSTANCE_COUNT] centers = {
        { 0.0, -0.15, 0.0 },
        { -3.0, 1.0, -2.5 }, { 0.0, 1.6, 0.0 }, { 3.2, 0.8, -1.0 },
        { -1.5, 0.6, 2.8 },  { 2.0, 2.6, 2.2 }, { -3.5, 0.9, 1.5 },
        { 1.0, 0.5, -3.4 },  { 4.0, 1.4, 3.0 },
    };
    float[<3>][INSTANCE_COUNT] scales = {
        { 9.0, 0.15, 9.0 },
        { 0.9, 1.0, 0.9 }, { 0.8, 1.6, 0.8 }, { 1.1, 0.8, 1.1 },
        { 0.6, 0.6, 0.6 }, { 0.7, 0.9, 0.7 }, { 0.5, 0.9, 0.5 },
        { 0.8, 0.5, 0.8 }, { 0.6, 1.4, 0.6 },
    };
    float[<3>][INSTANCE_COUNT] colors = {
        { 0.55, 0.57, 0.60 },
        { 0.85, 0.35, 0.30 }, { 0.30, 0.60, 0.85 }, { 0.90, 0.75, 0.25 },
        { 0.40, 0.80, 0.45 }, { 0.75, 0.45, 0.85 }, { 0.90, 0.55, 0.30 },
        { 0.35, 0.75, 0.75 }, { 0.80, 0.80, 0.80 },
    };
    for (uint i = 0; i < INSTANCE_COUNT; i++) {
        usz base = (usz)i * 12;
        for (uint c = 0; c < 3; c++) {
            out[base + c]     = centers[i][c];
            out[base + 4 + c] = scales[i][c];
            out[base + 8 + c] = colors[i][c];
        }
        out[base + 3] = 0.0f;
        out[base + 7] = 0.0f;
        out[base + 11] = 1.0f;
    }
}

fn void write_matrix(gpu::Vec4f* columns, sample_camera::Mat4 m) {
    for (uint c = 0; c < 4; c++) {
        columns[c] = { m[c * 4], m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3] };
    }
}

fn void? recover_swapchain(gpu::Device* device, gpu::SwapchainHandle swapchain, sample_window::SampleWindow* window, uint* width, uint* height, bool[] image_seen) {
    sample_window::pixel_size(window, width, height);
    gpu::resize_swapchain(device, swapchain, *width, *height)!;
    foreach (&seen : image_seen) *seen = false;
}

fn gpu::TextureHandle? create_depth_texture(gpu::Device* device, uint width, uint height, bool sampled, ZString name) {
    gpu::TextureDesc desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = width,
        .height     = height,
        .format     = gpu::Format.D32_FLOAT,
        .usage      = { .depth_attach, .sampled = sampled },
        .debug_name = name,
    };
    return gpu::create_texture(device, &desc);
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("shadow_mapping: FAIL (%s)", err);
        return 1;
    }
    io::printn("shadow_mapping: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l shadow mapping", 1024, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::DeviceDesc device_desc = {
        .backend             = gpu::BackendKind.VULKAN,
        .enable_validation   = true,
        .enable_presentation = true,
        .frames_in_flight    = 2,
        .application_name    = "shadow_mapping",
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
        .debug_name       = "shadow_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    defer (void)gpu::destroy_swapchain(&device, swapchain);

    gpu::TextureHandle shadow_map = create_depth_texture(&device, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, true, "shadow_map")!;
    defer (void)gpu::destroy_texture(&device, shadow_map);
    gpu::TextureIndex shadow_index = gpu::create_texture_descriptor(&device, shadow_map, null)!;
    defer (void)gpu::destroy_texture_descriptor(&device, shadow_index);

    gpu::TextureHandle scene_depth = create_depth_texture(&device, width, height, false, "scene_depth")!;
    defer (void)gpu::destroy_texture(&device, scene_depth);

    gpu::SamplerDesc shadow_sampler_desc = {
        .min_filter     = gpu::Filter.NEAREST,
        .mag_filter     = gpu::Filter.NEAREST,
        .address_u      = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v      = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w      = gpu::AddressMode.CLAMP_TO_EDGE,
        .compare_enable = true,
        .compare        = gpu::CompareOp.LESS,
    };
    gpu::SamplerIndex shadow_sampler = gpu::create_sampler(&device, &shadow_sampler_desc)!;
    defer (void)gpu::destroy_sampler(&device, shadow_sampler);

    gpu::BufferDesc vertex_desc = {
        .size        = CUBE_VERTEX_COUNT * 16,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = "cube_vertices",
    };
    gpu::BufferHandle vertices = gpu::create_buffer(&device, &vertex_desc)!;
    defer (void)gpu::destroy_buffer(&device, vertices);
    gpu::GpuSpan vertex_span = gpu::get_buffer_span(&device, vertices)!;
    write_cube_vertices((float*)vertex_span.cpu);
    gpu::flush_buffer(&device, vertices, 0, 0)!;

    gpu::BufferDesc instances_desc = {
        .size        = INSTANCE_COUNT * 48,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = "instances",
    };
    gpu::BufferHandle instances = gpu::create_buffer(&device, &instances_desc)!;
    defer (void)gpu::destroy_buffer(&device, instances);
    gpu::GpuSpan instances_span = gpu::get_buffer_span(&device, instances)!;
    write_instances((float*)instances_span.cpu);
    gpu::flush_buffer(&device, instances, 0, 0)!;

    gpu::ShaderDesc sh_vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = SHADOW_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle sh_vert = gpu::create_shader(&device, &sh_vert_sd)!;
    defer (void)gpu::destroy_shader(&device, sh_vert);
    gpu::ShaderDesc sh_frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = SHADOW_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle sh_frag = gpu::create_shader(&device, &sh_frag_sd)!;
    defer (void)gpu::destroy_shader(&device, sh_frag);
    gpu::ShaderDesc sc_vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = SCENE_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle sc_vert = gpu::create_shader(&device, &sc_vert_sd)!;
    defer (void)gpu::destroy_shader(&device, sc_vert);
    gpu::ShaderDesc sc_frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = SCENE_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle sc_frag = gpu::create_shader(&device, &sc_frag_sd)!;
    defer (void)gpu::destroy_shader(&device, sc_frag);

    gpu::GraphicsPipelineDesc shadow_pd = {
        .vertex_shader   = sh_vert,
        .fragment_shader = sh_frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .depth           = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.LESS },
        .raster          = { .cull_mode = gpu::CullMode.FRONT, .depth_bias_slope = 1.0f },
        .depth_format    = gpu::Format.D32_FLOAT,
        .debug_name      = "shadow_pass",
    };
    gpu::PipelineHandle shadow_pipe = gpu::create_graphics_pipeline(&device, &shadow_pd)!;
    defer (void)gpu::destroy_pipeline(&device, shadow_pipe);

    gpu::Format[1] color_formats = { gpu::Format.BGRA8_UNORM };
    gpu::GraphicsPipelineDesc scene_pd = {
        .vertex_shader   = sc_vert,
        .fragment_shader = sc_frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .depth           = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.LESS },
        .color_formats   = color_formats[..],
        .depth_format    = gpu::Format.D32_FLOAT,
        .debug_name      = "shadowed_scene",
    };
    gpu::PipelineHandle scene_pipe = gpu::create_graphics_pipeline(&device, &scene_pd)!;
    defer (void)gpu::destroy_pipeline(&device, scene_pipe);

    sample_camera::OrbitCamera camera = { .yaw = 0.7f, .pitch = 0.55f, .radius = 15.0f, .target = { 0, 0.5f, 0 } };
    sample_camera::Mat4 view_proj = sample_camera::mul(
        sample_camera::perspective(1.0f, (float)width / (float)height, 0.1f, 100.0f),
        camera.view());

    bool shadow_map_initialized = false;
    bool scene_depth_fresh = true;
    bool[MAX_TRACKED_IMAGES] image_seen;
    long frame = 0;
    bool running = true;
    while (running) {
        sample_window::WindowEvents events = sample_window::pump_events(&window);
        if (events.quit) break;
        if (events.resized) {
            recover_swapchain(
                device:     &device,
                swapchain:  swapchain,
                window:     &window,
                width:      &width,
                height:     &height,
                image_seen: image_seen[..],
            )!;
            gpu::destroy_texture(&device, scene_depth)!;
            scene_depth = create_depth_texture(&device, width, height, false, "scene_depth")!;
            scene_depth_fresh = true;
            view_proj = sample_camera::mul(
                sample_camera::perspective(1.0f, (float)width / (float)height, 0.1f, 100.0f),
                camera.view());
        }

        gpu::begin_frame(&device)!;

        gpu::AcquiredImage acquired;
        if (try image = gpu::acquire_next_image(&device, swapchain)) {
            acquired = image;
        } else {
            recover_swapchain(
                device:     &device,
                swapchain:  swapchain,
                window:     &window,
                width:      &width,
                height:     &height,
                image_seen: image_seen[..],
            )!;
            gpu::end_frame(&device)!;
            continue;
        }

        // Orbiting directional light: position circles the scene, always
        // looking at the origin; orthographic projection = directional.
        float angle = (float)frame * 0.015f + 0.8f;
        float[<3>] light_pos = { math::cos(angle) * 12.0f, 10.0f, math::sin(angle) * 12.0f };
        float[<3>] light_dir_v = -sample_camera::normalize(-light_pos);
        sample_camera::Mat4 light_vp = sample_camera::mul(
            sample_camera::ortho(LIGHT_EXTENT, 1.0f, 30.0f),
            sample_camera::look_at(light_pos, { 0, 0, 0 }, { 0, 1, 0 }));

        gpu::GpuSpan shadow_span = gpu::alloc_frame_span(&device, ShadowPassRoot::size, 16)!;
        ShadowPassRoot* shadow_root = (ShadowPassRoot*)shadow_span.cpu;
        write_matrix(&shadow_root.light_vp_c0, light_vp);
        shadow_root.vertex_gpu    = vertex_span.gpu;
        shadow_root.instances_gpu = instances_span.gpu;

        gpu::GpuSpan scene_span = gpu::alloc_frame_span(&device, ScenePassRoot::size, 16)!;
        ScenePassRoot* scene_root = (ScenePassRoot*)scene_span.cpu;
        write_matrix(&scene_root.view_proj_c0, view_proj);
        write_matrix(&scene_root.light_vp_c0, light_vp);
        scene_root.light_dir      = { light_dir_v[0], light_dir_v[1], light_dir_v[2], 0.0f };
        scene_root.vertex_gpu     = vertex_span.gpu;
        scene_root.instances_gpu  = instances_span.gpu;
        scene_root.shadow_map     = shadow_index;
        scene_root.shadow_sampler = shadow_sampler;

        gpu::CommandList cmd = gpu::begin_commands(&device, gpu::QueueKind.GRAPHICS)!;

        // Shadow map: back to writable (from sampled after the first frame).
        gpu::TextureBarrier shadow_to_write = {
            .texture       = shadow_map,
            .before_stage  = shadow_map_initialized ? gpu::Stage.FRAGMENT_SHADER : gpu::Stage.HOST,
            .after_stage   = gpu::Stage.DEPTH_STENCIL,
            .before_hazard = shadow_map_initialized ? gpu::Hazard.SHADER_READ : gpu::Hazard.HOST_WRITE,
            .after_hazard  = gpu::Hazard.DEPTH_WRITE,
            .old_layout    = shadow_map_initialized ? gpu::TextureLayout.SHADER_READ : gpu::TextureLayout.UNDEFINED,
            .new_layout    = gpu::TextureLayout.DEPTH_STENCIL,
        };
        gpu::cmd_texture_barrier(&cmd, &shadow_to_write)!;
        shadow_map_initialized = true;

        gpu::DepthTargetDesc shadow_target = {
            .texture  = shadow_map,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc shadow_pass = { .depth = &shadow_target, .width = SHADOW_MAP_SIZE, .height = SHADOW_MAP_SIZE };
        gpu::cmd_begin_render_pass(&cmd, &shadow_pass)!;
        gpu::cmd_draw(
            commands:       &cmd,
            pipeline:       shadow_pipe,
            vertex_root:    shadow_span.gpu,
            fragment_root:  shadow_span.gpu,
            vertex_count:   CUBE_VERTEX_COUNT,
            instance_count: INSTANCE_COUNT,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier shadow_to_read = {
            .texture       = shadow_map,
            .before_stage  = gpu::Stage.DEPTH_STENCIL,
            .after_stage   = gpu::Stage.FRAGMENT_SHADER,
            .before_hazard = gpu::Hazard.DEPTH_WRITE,
            .after_hazard  = gpu::Hazard.SHADER_READ,
            .old_layout    = gpu::TextureLayout.DEPTH_STENCIL,
            .new_layout    = gpu::TextureLayout.SHADER_READ,
        };
        gpu::cmd_texture_barrier(&cmd, &shadow_to_read)!;

        if (scene_depth_fresh) {
            gpu::TextureBarrier depth_init = {
                .texture       = scene_depth,
                .before_stage  = gpu::Stage.HOST,
                .after_stage   = gpu::Stage.DEPTH_STENCIL,
                .before_hazard = gpu::Hazard.HOST_WRITE,
                .after_hazard  = gpu::Hazard.DEPTH_WRITE,
                .old_layout    = gpu::TextureLayout.UNDEFINED,
                .new_layout    = gpu::TextureLayout.DEPTH_STENCIL,
            };
            gpu::cmd_texture_barrier(&cmd, &depth_init)!;
            scene_depth_fresh = false;
        }

        gpu::TextureBarrier to_attach = {
            .texture       = acquired.texture,
            .before_stage  = image_seen[acquired.index] ? gpu::Stage.PRESENT : gpu::Stage.HOST,
            .after_stage   = gpu::Stage.COLOR_ATTACHMENT,
            .before_hazard = image_seen[acquired.index] ? gpu::Hazard.PRESENT_READ : gpu::Hazard.HOST_WRITE,
            .after_hazard  = gpu::Hazard.COLOR_WRITE,
            .old_layout    = image_seen[acquired.index] ? gpu::TextureLayout.PRESENT : gpu::TextureLayout.UNDEFINED,
            .new_layout    = gpu::TextureLayout.COLOR_ATTACHMENT,
        };
        gpu::cmd_texture_barrier(&cmd, &to_attach)!;
        image_seen[acquired.index] = true;

        gpu::ColorTargetDesc[1] colors = {{
            .texture  = acquired.texture,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.53f, 0.66f, 0.85f, 1.0f } },
        }};
        gpu::DepthTargetDesc scene_depth_target = {
            .texture  = scene_depth,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc scene_pass = { .colors = colors[..], .depth = &scene_depth_target, .width = width, .height = height };
        gpu::cmd_begin_render_pass(&cmd, &scene_pass)!;
        gpu::cmd_draw(
            commands:       &cmd,
            pipeline:       scene_pipe,
            vertex_root:    scene_span.gpu,
            fragment_root:  scene_span.gpu,
            vertex_count:   CUBE_VERTEX_COUNT,
            instance_count: INSTANCE_COUNT,
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
        gpu::end_commands(&device, &cmd)!;

        gpu::CommandList[1] lists = { cmd };
        gpu::SubmitDesc submit = { .command_lists = lists[..], .swapchain = swapchain };
        gpu::submit(&device, &submit)!;

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                device:      &device,
                src:         acquired.texture,
                width:       width,
                height:      height,
                format:      gpu::Format.BGRA8_UNORM,
                from_stage:  gpu::Stage.PRESENT,
                from_hazard: gpu::Hazard.PRESENT_READ,
                from_layout: gpu::TextureLayout.PRESENT,
                path:        options.screenshot_path,
            )!;
        }

        gpu::PresentDesc present_desc = { .swapchain = swapchain };
        if (catch err = gpu::present(&device, &present_desc)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            recover_swapchain(
                device:     &device,
                swapchain:  swapchain,
                window:     &window,
                width:      &width,
                height:     &height,
                image_seen: image_seen[..],
            )!;
        }

        gpu::end_frame(&device)!;

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
}
