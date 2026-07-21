module shadow_mapping;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;
import std::math;

const char[*] SHADOW_VERT_SPIRV = $embed("shaders/shadow.vert.spv");
const char[*] SHADOW_FRAG_SPIRV = $embed("shaders/shadow.frag.spv");
const char[*] SCENE_VERT_SPIRV  = $embed("shaders/scene.vert.spv");
const char[*] SCENE_FRAG_SPIRV  = $embed("shaders/scene.frag.spv");

const uint CUBE_VERTEX_COUNT = 36;
const uint INSTANCE_COUNT = 9;
const float LIGHT_EXTENT = 14.0f;
const usz UPLOAD_BYTES_PER_SLOT = ShadowPassRoot::size + ScenePassRoot::size;

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

fn gpu::TextureUse? swapchain_texture_use(gpu::TextureUse use) {
    switch (use) {
        case gpu::TextureUse.UNDEFINED: return gpu::TextureUse.UNDEFINED;
        case gpu::TextureUse.PRESENT:   return gpu::TextureUse.PRESENT;
        default:                           return gpu::INVALID_RESOURCE_STATE~;
    }
}

fn gpu::TextureHandle? create_depth_texture(gpu::Device* device, uint width, uint height, bool sampled, ZString name) {
    gpu::TextureDesc desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = width,
        .height     = height,
        .format     = gpu::Format.D32_FLOAT,
        .usage      = { .depth_attach, .sampled = sampled },
        .access     = { .graphics },
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

    gpu::RuntimeDesc runtime_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "shadow_mapping",
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
            debug_name:    "shadow_root_upload",
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
        .debug_name       = "shadow_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);

    gpu::TextureHandle shadow_map = create_depth_texture(&device, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, true, "shadow_map")!;
    defer (void)gpu::destroy_texture(&device, shadow_map);
    gpu::TextureView shadow_view = gpu::create_texture_view(&device, shadow_map, null)!;
    defer (void)gpu::destroy_texture_view(&device, shadow_view);
    gpu::TextureIndex shadow_index = shadow_view.index;
    gpu::AttachmentViewDesc shadow_attachment_desc = { .texture = shadow_map };
    gpu::AttachmentViewHandle shadow_attachment = gpu::create_attachment_view(
        &device,
        &shadow_attachment_desc,
    )!;
    defer (void)gpu::destroy_attachment_view(&device, shadow_attachment);

    gpu::TextureHandle scene_depth;
    gpu::AttachmentViewHandle scene_depth_view;
    uint scene_depth_width;
    uint scene_depth_height;
    bool scene_depth_valid = false;
    if (!swapchain_info.dormant) {
        scene_depth = create_depth_texture(
            device:  &device,
            width:   swapchain_info.width,
            height:  swapchain_info.height,
            sampled: false,
            name:    "scene_depth",
        )!;
        {
            defer catch (void)gpu::destroy_texture(&device, scene_depth);
            gpu::AttachmentViewDesc scene_depth_view_desc = {
                .texture = scene_depth,
            };
            scene_depth_view = gpu::create_attachment_view(
                &device,
                &scene_depth_view_desc,
            )!;
        }
        scene_depth_width = swapchain_info.width;
        scene_depth_height = swapchain_info.height;
        scene_depth_valid = true;
    }
    defer {
        if (scene_depth_valid) {
            (void)gpu::destroy_attachment_view(&device, scene_depth_view);
            (void)gpu::destroy_texture(&device, scene_depth);
        }
    }

    gpu::SamplerDesc shadow_sampler_desc = {
        .min_filter     = gpu::Filter.NEAREST,
        .mag_filter     = gpu::Filter.NEAREST,
        .address_u      = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v      = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w      = gpu::AddressMode.CLAMP_TO_EDGE,
        .compare_enable = true,
        .compare        = gpu::CompareOp.LESS,
    };
    gpu::Sampler shadow_sampler_identity =
        gpu::intern_sampler(&device, &shadow_sampler_desc)!;
    gpu::SamplerIndex shadow_sampler =
        gpu::publish_sampler(&device, shadow_sampler_identity)!;

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

    gpu::ShaderDesc sh_vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = SHADOW_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode sh_vert = gpu::prepare_shader_code(&sh_vert_sd)!;
    gpu::ShaderDesc sh_frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = SHADOW_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode sh_frag = gpu::prepare_shader_code(&sh_frag_sd)!;
    gpu::ShaderDesc sc_vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = SCENE_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode sc_vert = gpu::prepare_shader_code(&sc_vert_sd)!;
    gpu::ShaderDesc sc_frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = SCENE_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode sc_frag = gpu::prepare_shader_code(&sc_frag_sd)!;

    gpu::GraphicsPipelineDesc shadow_pd = {
        .vertex_shader   = sh_vert,
        .fragment_shader = sh_frag,
        .depth_format    = gpu::Format.D32_FLOAT,
        .debug_name      = "shadow_pass",
    };
    gpu::PipelineHandle shadow_pipe = gpu::create_graphics_pipeline(&device, &shadow_pd)!;
    defer (void)gpu::destroy_pipeline(&device, shadow_pipe);

    gpu::ColorTargetState[1] color_targets = {{
        .format     = swapchain_info.format,
        .write_mask = gpu::COLOR_WRITE_ALL,
    }};
    gpu::GraphicsPipelineDesc scene_pd = {
        .vertex_shader   = sc_vert,
        .fragment_shader = sc_frag,
        .colors          = color_targets[..],
        .depth_format    = gpu::Format.D32_FLOAT,
        .debug_name      = "shadowed_scene",
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

    sample_camera::OrbitCamera camera = { .yaw = 0.7f, .pitch = 0.55f, .radius = 15.0f, .target = { 0, 0.5f, 0 } };
    sample_camera::Mat4 view_proj;

    bool shadow_map_initialized = false;
    bool scene_depth_fresh = true;
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

        bool pipeline_changed = !scene_pipe_valid || color_targets[0].format != swapchain_info.format;
        bool depth_changed = !scene_depth_valid
            || scene_depth_width != swapchain_info.width
            || scene_depth_height != swapchain_info.height;
        if (pipeline_changed || depth_changed) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
        }
        if (pipeline_changed) {
            if (scene_pipe_valid) gpu::destroy_pipeline(&device, scene_pipe)!;
            scene_pipe_valid = false;
            color_targets[0].format = swapchain_info.format;
            scene_pipe = gpu::create_graphics_pipeline(&device, &scene_pd)!;
            scene_pipe_valid = true;
        }
        if (depth_changed) {
            if (scene_depth_valid) {
                gpu::destroy_attachment_view(&device, scene_depth_view)!;
                gpu::destroy_texture(&device, scene_depth)!;
            }
            scene_depth_valid = false;
            scene_depth = create_depth_texture(
                device:  &device,
                width:   swapchain_info.width,
                height:  swapchain_info.height,
                sampled: false,
                name:    "scene_depth",
            )!;
            {
                defer catch (void)gpu::destroy_texture(&device, scene_depth);
                gpu::AttachmentViewDesc scene_depth_view_desc = {
                    .texture = scene_depth,
                };
                scene_depth_view = gpu::create_attachment_view(
                    &device,
                    &scene_depth_view_desc,
                )!;
            }
            scene_depth_width = swapchain_info.width;
            scene_depth_height = swapchain_info.height;
            scene_depth_valid = true;
            scene_depth_fresh = true;
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

        gpu::AttachmentViewHandle color_view = acquired.attachment_view;

        sample_frame_upload::FrameUploadBatch upload_batch =
            sample_frame_upload::begin_frame_upload(&upload_ring)!;
        defer catch {
            if (upload_batch.ring != null) {
                (void)sample_frame_upload::cancel_frame_upload(&upload_batch);
            }
        };

        // Orbiting directional light: position circles the scene, always
        // looking at the origin; orthographic projection = directional.
        float angle = (float)frame * 0.015f + 0.8f;
        float[<3>] light_pos = { math::cos(angle) * 12.0f, 10.0f, math::sin(angle) * 12.0f };
        float[<3>] light_dir_v = -sample_camera::normalize(-light_pos);
        sample_camera::Mat4 light_vp = sample_camera::mul(
            sample_camera::ortho(LIGHT_EXTENT, 1.0f, 30.0f),
            sample_camera::look_at(light_pos, { 0, 0, 0 }, { 0, 1, 0 }));

        gpu::GpuSpan shadow_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      ShadowPassRoot::size,
            alignment: 16,
        )!;
        ShadowPassRoot* shadow_root = (ShadowPassRoot*)gpu::get_span_mapping(&device, shadow_span)!.ptr;
        write_matrix(&shadow_root.light_vp_c0, light_vp);
        shadow_root.vertex_gpu    = vertex_address;
        shadow_root.instances_gpu = instances_address;
        gpu::GpuAddress shadow_root_address = gpu::get_span_address(&device, shadow_span)!;

        gpu::GpuSpan scene_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      ScenePassRoot::size,
            alignment: 16,
        )!;
        ScenePassRoot* scene_root = (ScenePassRoot*)gpu::get_span_mapping(&device, scene_span)!.ptr;
        write_matrix(&scene_root.view_proj_c0, view_proj);
        write_matrix(&scene_root.light_vp_c0, light_vp);
        scene_root.light_dir      = { light_dir_v[0], light_dir_v[1], light_dir_v[2], 0.0f };
        scene_root.vertex_gpu     = vertex_address;
        scene_root.instances_gpu  = instances_address;
        scene_root.shadow_map     = shadow_index;
        scene_root.shadow_sampler = shadow_sampler;
        gpu::GpuAddress scene_root_address = gpu::get_span_address(&device, scene_span)!;
        sample_frame_upload::flush_frame_upload(&upload_batch)!;

        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
        defer (void)gpu::discard_commands(&cmd);

        // Shadow map: back to writable (from sampled after the first frame).
        gpu::TextureBarrier shadow_to_write = {
            .texture       = shadow_map,
            .before        = shadow_map_initialized ? gpu::TextureUse.SAMPLED_FRAGMENT : gpu::TextureUse.UNDEFINED,
            .after         = gpu::TextureUse.DEPTH_ATTACHMENT,
        };
        gpu::cmd_texture_barrier(&cmd, &shadow_to_write)!;
        shadow_map_initialized = true;

        gpu::DepthTargetDesc shadow_target = {
            .view     = shadow_attachment,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc shadow_pass = { .depth = &shadow_target, .width = SHADOW_MAP_SIZE, .height = SHADOW_MAP_SIZE };
        gpu::cmd_bind_pipeline(&cmd, shadow_pipe)!;
        gpu::cmd_begin_render_pass(&cmd, &shadow_pass)!;
        gpu::DynamicRasterState shadow_raster = {
            .cull_mode           = gpu::CullMode.FRONT,
            .depth_bias_enable   = true,
            .depth_bias_constant = 0.0f,
            .depth_bias_slope    = 1.0f,
        };
        gpu::cmd_set_raster_state(&cmd, &shadow_raster)!;
        gpu::DepthState depth_state = {
            .test_enable  = true,
            .write_enable = true,
            .compare      = gpu::CompareOp.LESS,
        };
        gpu::cmd_set_depth_state(&cmd, &depth_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    shadow_root_address,
            fragment_root:  shadow_root_address,
            vertex_count:   CUBE_VERTEX_COUNT,
            instance_count: INSTANCE_COUNT,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier shadow_to_read = {
            .texture       = shadow_map,
            .before        = gpu::TextureUse.DEPTH_ATTACHMENT,
            .after         = gpu::TextureUse.SAMPLED_FRAGMENT,
        };
        gpu::cmd_texture_barrier(&cmd, &shadow_to_read)!;

        if (scene_depth_fresh) {
            gpu::TextureBarrier depth_init = {
                .texture       = scene_depth,
                .before        = gpu::TextureUse.UNDEFINED,
                .after         = gpu::TextureUse.DEPTH_ATTACHMENT,
            };
            gpu::cmd_texture_barrier(&cmd, &depth_init)!;
            scene_depth_fresh = false;
        }

        gpu::TextureBarrier to_attach = gpu::texture_transition(
            texture: acquired.texture,
            before:  swapchain_texture_use(acquired.prior_use)!,
            after:   gpu::TextureUse.COLOR_ATTACHMENT,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_attach)!;

        gpu::ColorTargetDesc[1] colors = {{
            .view     = color_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.53f, 0.66f, 0.85f, 1.0f } },
        }};
        gpu::DepthTargetDesc scene_depth_target = {
            .view     = scene_depth_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc scene_pass = { .colors = colors[..], .depth = &scene_depth_target, .width = width, .height = height };
        gpu::cmd_bind_pipeline(&cmd, scene_pipe)!;
        gpu::cmd_begin_render_pass(&cmd, &scene_pass)!;
        gpu::cmd_set_depth_state(&cmd, &depth_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    scene_root_address,
            fragment_root:  scene_root_address,
            vertex_count:   CUBE_VERTEX_COUNT,
            instance_count: INSTANCE_COUNT,
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
            .command_lists    = lists[..],
            .readiness        = acquired.readiness,
            .readiness_before = { .color_output },
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
}
