module deferred_shading;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_window;
import std::io;
import std::math;

const char[*] GEOM_VERT_SPIRV    = $embed("shaders/geometry.vert.spv");
const char[*] GEOM_FRAG_SPIRV    = $embed("shaders/geometry.frag.spv");
const char[*] RESOLVE_VERT_SPIRV = $embed("shaders/resolve.vert.spv");
const char[*] RESOLVE_FRAG_SPIRV = $embed("shaders/resolve.frag.spv");

const uint MAX_TRACKED_IMAGES = 8;
const uint CUBE_VERTEX_COUNT = 36;
const uint INSTANCE_COUNT = 9;

struct CubeFace {
    float[<3>] normal;
    float[<3>] u_axis;
    float[<3>] v_axis;
}

const CubeFace[6] CUBE_FACES = {
    { { 0, 0, 1 },  { 1, 0, 0 },  { 0, 1, 0 } },
    { { 0, 0, -1 }, { -1, 0, 0 }, { 0, 1, 0 } },
    { { 1, 0, 0 },  { 0, 0, -1 }, { 0, 1, 0 } },
    { { -1, 0, 0 }, { 0, 0, 1 },  { 0, 1, 0 } },
    { { 0, 1, 0 },  { 1, 0, 0 },  { 0, 0, -1 } },
    { { 0, -1, 0 }, { 1, 0, 0 },  { 0, 0, 1 } },
};

<* Two vec4s per vertex: unit-cube position, face normal. *>
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
            out[cursor++] = 0.0f;
            out[cursor++] = face.normal[0];
            out[cursor++] = face.normal[1];
            out[cursor++] = face.normal[2];
            out[cursor++] = 0.0f;
        }
    }
}

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
        { 0.75, 0.76, 0.78 },
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

fn void write_lights(float* out, float time) {
    for (uint i = 0; i < LIGHT_COUNT; i++) {
        float phase = (float)i / LIGHT_COUNT * 6.2831853f;
        float orbit_radius = 3.0f + 3.5f * (float)(i % 4) / 4.0f;
        float speed = 0.4f + 0.15f * (float)(i % 3);
        float angle = phase + time * speed;
        usz base = (usz)i * 8;
        out[base]     = math::cos(angle) * orbit_radius;
        out[base + 1] = 0.6f + 1.8f * (float)((i * 7) % 5) / 5.0f;
        out[base + 2] = math::sin(angle) * orbit_radius;
        out[base + 3] = 4.5f;
        out[base + 4] = 0.5f + 0.5f * math::cos(phase);
        out[base + 5] = 0.5f + 0.5f * math::cos(phase + 2.094f);
        out[base + 6] = 0.5f + 0.5f * math::cos(phase + 4.189f);
        out[base + 7] = 1.0f;
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

struct GBuffer {
    gpu::TextureHandle albedo;
    gpu::TextureHandle normal;
    gpu::TextureHandle position;
    gpu::TextureHandle depth;
    gpu::TextureIndex  albedo_index;
    gpu::TextureIndex  normal_index;
    gpu::TextureIndex  position_index;
    bool               fresh;
}

fn gpu::TextureHandle? create_target(gpu::Device* device, uint width, uint height, gpu::Format format, ZString name) {
    gpu::TextureDesc desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = width,
        .height     = height,
        .format     = format,
        .usage      = { .color_attach, .sampled },
        .debug_name = name,
    };
    return gpu::create_texture(device, &desc);
}

fn GBuffer? create_gbuffer(gpu::Device* device, uint width, uint height) {
    GBuffer g;
    g.albedo   = create_target(device, width, height, gpu::Format.RGBA8_UNORM, "g_albedo")!;
    g.normal   = create_target(device, width, height, gpu::Format.RGBA16_FLOAT, "g_normal")!;
    g.position = create_target(device, width, height, gpu::Format.RGBA16_FLOAT, "g_position")!;
    gpu::TextureDesc depth_desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = width,
        .height     = height,
        .format     = gpu::Format.D32_FLOAT,
        .usage      = { .depth_attach },
        .debug_name = "g_depth",
    };
    g.depth = gpu::create_texture(device, &depth_desc)!;
    g.albedo_index   = gpu::create_texture_descriptor(device, g.albedo, null)!;
    g.normal_index   = gpu::create_texture_descriptor(device, g.normal, null)!;
    g.position_index = gpu::create_texture_descriptor(device, g.position, null)!;
    g.fresh = true;
    return g;
}

fn void destroy_gbuffer(gpu::Device* device, GBuffer* g) {
    (void)gpu::destroy_texture_descriptor(device, g.position_index);
    (void)gpu::destroy_texture_descriptor(device, g.normal_index);
    (void)gpu::destroy_texture_descriptor(device, g.albedo_index);
    (void)gpu::destroy_texture(device, g.depth);
    (void)gpu::destroy_texture(device, g.position);
    (void)gpu::destroy_texture(device, g.normal);
    (void)gpu::destroy_texture(device, g.albedo);
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("deferred_shading: FAIL (%s)", err);
        return 1;
    }
    io::printn("deferred_shading: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l deferred shading", 1024, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::DeviceDesc device_desc = {
        .backend             = gpu::BackendKind.VULKAN,
        .enable_validation   = true,
        .enable_presentation = true,
        .frames_in_flight    = 2,
        .application_name    = "deferred_shading",
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
        .debug_name       = "deferred_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    defer (void)gpu::destroy_swapchain(&device, swapchain);

    GBuffer gbuffer = create_gbuffer(&device, width, height)!;
    defer destroy_gbuffer(&device, &gbuffer);

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex gbuffer_sampler = gpu::create_sampler(&device, &sampler_desc)!;
    defer (void)gpu::destroy_sampler(&device, gbuffer_sampler);

    gpu::BufferDesc vertex_desc = {
        .size        = CUBE_VERTEX_COUNT * 32,
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

    gpu::BufferDesc lights_desc = {
        .size        = LIGHT_COUNT * 32,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = "lights",
    };
    gpu::BufferHandle lights = gpu::create_buffer(&device, &lights_desc)!;
    defer (void)gpu::destroy_buffer(&device, lights);
    gpu::GpuSpan lights_span = gpu::get_buffer_span(&device, lights)!;

    gpu::ShaderDesc gv_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = GEOM_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle geom_vert = gpu::create_shader(&device, &gv_sd)!;
    defer (void)gpu::destroy_shader(&device, geom_vert);
    gpu::ShaderDesc gf_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = GEOM_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle geom_frag = gpu::create_shader(&device, &gf_sd)!;
    defer (void)gpu::destroy_shader(&device, geom_frag);
    gpu::ShaderDesc rv_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = RESOLVE_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle resolve_vert = gpu::create_shader(&device, &rv_sd)!;
    defer (void)gpu::destroy_shader(&device, resolve_vert);
    gpu::ShaderDesc rf_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = RESOLVE_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle resolve_frag = gpu::create_shader(&device, &rf_sd)!;
    defer (void)gpu::destroy_shader(&device, resolve_frag);

    gpu::Format[3] gbuffer_formats = { gpu::Format.RGBA8_UNORM, gpu::Format.RGBA16_FLOAT, gpu::Format.RGBA16_FLOAT };
    gpu::GraphicsPipelineDesc geom_pd = {
        .vertex_shader   = geom_vert,
        .fragment_shader = geom_frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .depth           = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.LESS },
        .color_formats   = gbuffer_formats[..],
        .depth_format    = gpu::Format.D32_FLOAT,
        .debug_name      = "gbuffer_pass",
    };
    gpu::PipelineHandle geom_pipe = gpu::create_graphics_pipeline(&device, &geom_pd)!;
    defer (void)gpu::destroy_pipeline(&device, geom_pipe);

    gpu::Format[1] swap_formats = { gpu::Format.BGRA8_UNORM };
    gpu::GraphicsPipelineDesc resolve_pd = {
        .vertex_shader   = resolve_vert,
        .fragment_shader = resolve_frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .color_formats   = swap_formats[..],
        .debug_name      = "resolve_pass",
    };
    gpu::PipelineHandle resolve_pipe = gpu::create_graphics_pipeline(&device, &resolve_pd)!;
    defer (void)gpu::destroy_pipeline(&device, resolve_pipe);

    sample_camera::OrbitCamera camera = { .yaw = 0.7f, .pitch = 0.5f, .radius = 14.0f, .target = { 0, 0.8f, 0 } };
    sample_camera::Mat4 view_proj = sample_camera::mul(
        sample_camera::perspective(1.0f, (float)width / (float)height, 0.1f, 100.0f),
        camera.view());

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
            gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
            destroy_gbuffer(&device, &gbuffer);
            gbuffer = create_gbuffer(&device, width, height)!;
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

        write_lights((float*)lights_span.cpu, (float)frame / 60.0f);
        gpu::flush_buffer(&device, lights, 0, 0)!;

        gpu::GpuSpan geom_span = gpu::alloc_frame_span(&device, GeometryRoot::size, 16)!;
        GeometryRoot* geom_root = (GeometryRoot*)geom_span.cpu;
        write_matrix(&geom_root.view_proj_c0, view_proj);
        geom_root.vertex_gpu    = vertex_span.gpu;
        geom_root.instances_gpu = instances_span.gpu;

        float[<3>] cam_pos = camera.position();
        gpu::GpuSpan resolve_span = gpu::alloc_frame_span(&device, ResolveRoot::size, 16)!;
        ResolveRoot* resolve_root = (ResolveRoot*)resolve_span.cpu;
        resolve_root.camera_pos      = { cam_pos[0], cam_pos[1], cam_pos[2], 1.0f };
        resolve_root.lights_gpu      = lights_span.gpu;
        resolve_root.albedo_target   = gbuffer.albedo_index;
        resolve_root.normal_target   = gbuffer.normal_index;
        resolve_root.position_target = gbuffer.position_index;
        resolve_root.gbuffer_sampler = gbuffer_sampler;
        resolve_root.light_count     = LIGHT_COUNT;

        gpu::CommandList cmd = gpu::begin_commands(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::TextureHandle[3] color_targets = { gbuffer.albedo, gbuffer.normal, gbuffer.position };
        foreach (target : color_targets) {
            gpu::TextureBarrier to_attach = {
                .texture       = target,
                .before_stage  = gbuffer.fresh ? gpu::Stage.HOST : gpu::Stage.FRAGMENT_SHADER,
                .after_stage   = gpu::Stage.COLOR_ATTACHMENT,
                .before_hazard = gbuffer.fresh ? gpu::Hazard.HOST_WRITE : gpu::Hazard.SHADER_READ,
                .after_hazard  = gpu::Hazard.COLOR_WRITE,
                .old_layout    = gbuffer.fresh ? gpu::TextureLayout.UNDEFINED : gpu::TextureLayout.SHADER_READ,
                .new_layout    = gpu::TextureLayout.COLOR_ATTACHMENT,
            };
            gpu::cmd_texture_barrier(&cmd, &to_attach)!;
        }
        if (gbuffer.fresh) {
            gpu::TextureBarrier depth_init = {
                .texture       = gbuffer.depth,
                .before_stage  = gpu::Stage.HOST,
                .after_stage   = gpu::Stage.DEPTH_STENCIL,
                .before_hazard = gpu::Hazard.HOST_WRITE,
                .after_hazard  = gpu::Hazard.DEPTH_WRITE,
                .old_layout    = gpu::TextureLayout.UNDEFINED,
                .new_layout    = gpu::TextureLayout.DEPTH_STENCIL,
            };
            gpu::cmd_texture_barrier(&cmd, &depth_init)!;
            gbuffer.fresh = false;
        }

        gpu::ColorTargetDesc[3] gbuffer_colors = {
            {
                .texture  = gbuffer.albedo,
                .load_op  = gpu::LoadOp.CLEAR,
                .store_op = gpu::StoreOp.STORE,
                .clear    = { .rgba = { 0, 0, 0, 0 } },
            },
            {
                .texture  = gbuffer.normal,
                .load_op  = gpu::LoadOp.CLEAR,
                .store_op = gpu::StoreOp.STORE,
                .clear    = { .rgba = { 0, 0, 0, 0 } },
            },
            {
                .texture  = gbuffer.position,
                .load_op  = gpu::LoadOp.CLEAR,
                .store_op = gpu::StoreOp.STORE,
                .clear    = { .rgba = { 0, 0, 0, 0 } },
            },
        };
        gpu::DepthTargetDesc gbuffer_depth = {
            .texture  = gbuffer.depth,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc geometry_pass = { .colors = gbuffer_colors[..], .depth = &gbuffer_depth, .width = width, .height = height };
        gpu::cmd_begin_render_pass(&cmd, &geometry_pass)!;
        gpu::cmd_draw(
            commands:       &cmd,
            pipeline:       geom_pipe,
            vertex_root:    geom_span.gpu,
            fragment_root:  geom_span.gpu,
            vertex_count:   CUBE_VERTEX_COUNT,
            instance_count: INSTANCE_COUNT,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        foreach (target : color_targets) {
            gpu::TextureBarrier to_read = {
                .texture       = target,
                .before_stage  = gpu::Stage.COLOR_ATTACHMENT,
                .after_stage   = gpu::Stage.FRAGMENT_SHADER,
                .before_hazard = gpu::Hazard.COLOR_WRITE,
                .after_hazard  = gpu::Hazard.SHADER_READ,
                .old_layout    = gpu::TextureLayout.COLOR_ATTACHMENT,
                .new_layout    = gpu::TextureLayout.SHADER_READ,
            };
            gpu::cmd_texture_barrier(&cmd, &to_read)!;
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

        gpu::ColorTargetDesc[1] swap_colors = {{
            .texture  = acquired.texture,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0, 0, 0, 1 } },
        }};
        gpu::RenderPassDesc resolve_pass = { .colors = swap_colors[..], .width = width, .height = height };
        gpu::cmd_begin_render_pass(&cmd, &resolve_pass)!;
        gpu::cmd_draw(
            commands:       &cmd,
            pipeline:       resolve_pipe,
            vertex_root:    resolve_span.gpu,
            fragment_root:  resolve_span.gpu,
            vertex_count:   3,
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
