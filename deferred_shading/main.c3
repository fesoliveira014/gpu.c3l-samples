module deferred_shading;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;
import std::math;

const char[*] GEOM_VERT_SPIRV    = $embed("shaders/geometry.vert.spv");
const char[*] GEOM_FRAG_SPIRV    = $embed("shaders/geometry.frag.spv");
const char[*] RESOLVE_VERT_SPIRV = $embed("shaders/resolve.vert.spv");
const char[*] RESOLVE_FRAG_SPIRV = $embed("shaders/resolve.frag.spv");

const uint CUBE_VERTEX_COUNT = 36;
const uint INSTANCE_COUNT = 9;
const usz UPLOAD_BYTES_PER_SLOT =
    LIGHT_COUNT * 32 + GeometryRoot::size + ResolveRoot::size;

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
        { -1.5, 0.6, 2.8 },  { 2.0, 0.9, 2.2 }, { -3.5, 0.9, 1.5 },
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

fn gpu::TextureUse? swapchain_texture_use(gpu::TextureLayout layout) {
    switch (layout) {
        case gpu::TextureLayout.UNDEFINED: return gpu::TextureUse.UNDEFINED;
        case gpu::TextureLayout.PRESENT:   return gpu::TextureUse.PRESENT;
        default:                           return gpu::INVALID_RESOURCE_STATE~;
    }
}

struct GBuffer {
    gpu::TextureHandle albedo;
    gpu::TextureHandle normal;
    gpu::TextureHandle position;
    gpu::TextureHandle depth;
    gpu::TextureView   albedo_view;
    gpu::TextureView   normal_view;
    gpu::TextureView   position_view;
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
        .access     = { .graphics },
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
        .access     = { .graphics },
        .debug_name = "g_depth",
    };
    g.depth = gpu::create_texture(device, &depth_desc)!;
    g.albedo_view   = gpu::create_texture_view(device, g.albedo, null)!;
    g.normal_view   = gpu::create_texture_view(device, g.normal, null)!;
    g.position_view = gpu::create_texture_view(device, g.position, null)!;
    g.albedo_index   = g.albedo_view.index;
    g.normal_index   = g.normal_view.index;
    g.position_index = g.position_view.index;
    g.fresh = true;
    return g;
}

fn void destroy_gbuffer(gpu::Device* device, GBuffer* g) {
    (void)gpu::destroy_texture_view(device, g.position_view);
    (void)gpu::destroy_texture_view(device, g.normal_view);
    (void)gpu::destroy_texture_view(device, g.albedo_view);
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

    gpu::RuntimeDesc runtime_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "deferred_shading",
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
            debug_name:    "deferred_root_upload",
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
        .debug_name       = "deferred_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)gpu::destroy_swapchain(&device, swapchain);

    GBuffer gbuffer;
    uint gbuffer_width;
    uint gbuffer_height;
    bool gbuffer_valid = false;
    if (!swapchain_info.dormant) {
        gbuffer = create_gbuffer(&device, swapchain_info.width, swapchain_info.height)!;
        gbuffer_width = swapchain_info.width;
        gbuffer_height = swapchain_info.height;
        gbuffer_valid = true;
    }
    defer {
        if (gbuffer_valid) destroy_gbuffer(&device, &gbuffer);
    }

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::Sampler gbuffer_sampler_identity = gpu::intern_sampler(&device, &sampler_desc)!;
    gpu::SamplerIndex gbuffer_sampler =
        gpu::publish_sampler(&device, gbuffer_sampler_identity)!;

    gpu::AllocationDesc vertex_desc = {
        .size         = CUBE_VERTEX_COUNT * 32,
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
        .size         = INSTANCE_COUNT * 48,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "instances",
    };
    gpu::GpuAllocation instances_allocation = gpu::allocate_memory(&device, &instances_desc)!;
    defer (void)gpu::free_allocation(&device, &instances_allocation);
    gpu::GpuSpan instances_span = gpu::get_allocation_span(&device, instances_allocation)!;
    write_instances((float*)gpu::get_span_mapping(&device, instances_span)!.ptr);
    gpu::flush_mapped_span(&device, instances_span)!;
    gpu::GpuAddress instances_address = gpu::get_span_address(&device, instances_span)!;

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

    gpu::Format[1] swap_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc resolve_pd = {
        .vertex_shader   = resolve_vert,
        .fragment_shader = resolve_frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .color_formats   = swap_formats[..],
        .debug_name      = "resolve_pass",
    };
    gpu::PipelineHandle resolve_pipe;
    bool resolve_pipe_valid = false;
    if (!swapchain_info.dormant) {
        resolve_pipe = gpu::create_graphics_pipeline(&device, &resolve_pd)!;
        resolve_pipe_valid = true;
    }
    defer {
        if (resolve_pipe_valid) (void)gpu::destroy_pipeline(&device, resolve_pipe);
    }

    sample_camera::OrbitCamera camera = { .yaw = 0.7f, .pitch = 0.5f, .radius = 14.0f, .target = { 0, 0.8f, 0 } };
    sample_camera::Mat4 view_proj;

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

        bool pipeline_changed = !resolve_pipe_valid || swap_formats[0] != swapchain_info.format;
        bool gbuffer_changed = !gbuffer_valid
            || gbuffer_width != swapchain_info.width
            || gbuffer_height != swapchain_info.height;
        if (pipeline_changed || gbuffer_changed) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
        }
        if (pipeline_changed) {
            if (resolve_pipe_valid) gpu::destroy_pipeline(&device, resolve_pipe)!;
            resolve_pipe_valid = false;
            swap_formats[0] = swapchain_info.format;
            resolve_pipe = gpu::create_graphics_pipeline(&device, &resolve_pd)!;
            resolve_pipe_valid = true;
        }
        if (gbuffer_changed) {
            if (gbuffer_valid) destroy_gbuffer(&device, &gbuffer);
            gbuffer_valid = false;
            gbuffer = create_gbuffer(&device, swapchain_info.width, swapchain_info.height)!;
            gbuffer_width = swapchain_info.width;
            gbuffer_height = swapchain_info.height;
            gbuffer_valid = true;
        }
        width = swapchain_info.width;
        height = swapchain_info.height;
        view_proj = sample_camera::mul(
            sample_camera::perspective(1.0f, (float)width / (float)height, 0.1f, 100.0f),
            camera.view());

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
        gpu::GpuSpan lights_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      LIGHT_COUNT * 32,
            alignment: 16,
        )!;
        write_lights((float*)gpu::get_span_mapping(&device, lights_span)!.ptr, (float)frame / 60.0f);
        gpu::GpuAddress lights_address = gpu::get_span_address(&device, lights_span)!;

        gpu::GpuSpan geom_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      GeometryRoot::size,
            alignment: 16,
        )!;
        GeometryRoot* geom_root = (GeometryRoot*)gpu::get_span_mapping(&device, geom_span)!.ptr;
        write_matrix(&geom_root.view_proj_c0, view_proj);
        geom_root.vertex_gpu    = vertex_address;
        geom_root.instances_gpu = instances_address;
        gpu::GpuAddress geometry_root_address = gpu::get_span_address(&device, geom_span)!;

        float[<3>] cam_pos = camera.position();
        gpu::GpuSpan resolve_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      ResolveRoot::size,
            alignment: 16,
        )!;
        ResolveRoot* resolve_root = (ResolveRoot*)gpu::get_span_mapping(&device, resolve_span)!.ptr;
        resolve_root.camera_pos      = { cam_pos[0], cam_pos[1], cam_pos[2], 1.0f };
        resolve_root.lights_gpu      = lights_address;
        resolve_root.albedo_target   = gbuffer.albedo_index;
        resolve_root.normal_target   = gbuffer.normal_index;
        resolve_root.position_target = gbuffer.position_index;
        resolve_root.gbuffer_sampler = gbuffer_sampler;
        resolve_root.light_count     = LIGHT_COUNT;
        gpu::GpuAddress resolve_root_address = gpu::get_span_address(&device, resolve_span)!;
        sample_frame_upload::flush_frame_upload(&upload_batch)!;

        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
        defer (void)gpu::discard_commands(&cmd);

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
            vertex_root:    geometry_root_address,
            fragment_root:  geometry_root_address,
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

        gpu::TextureBarrier to_attach = gpu::texture_transition(
            texture: acquired.texture,
            before:  swapchain_texture_use(acquired.prior_layout)!,
            after:   gpu::TextureUse.COLOR_ATTACHMENT,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_attach)!;

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
            vertex_root:    resolve_root_address,
            fragment_root:  resolve_root_address,
            vertex_count:   3,
            instance_count: 1,
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

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                device:              &device,
                producer_completion: last_graphics,
                queue_kind:          gpu::QueueKind.GRAPHICS,
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

        if (catch err = gpu::present(&device, &acquired, last_graphics)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
        }

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
}
