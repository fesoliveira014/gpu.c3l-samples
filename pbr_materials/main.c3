module pbr_materials;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_window;
import std::io;
import std::math;

const char[*] PBR_VERT_SPIRV = $embed("shaders/pbr.vert.spv");
const char[*] PBR_FRAG_SPIRV = $embed("shaders/pbr.frag.spv");

const uint GRID = 7;
const uint SPHERE_SEGMENTS = 32;
const uint SPHERE_RINGS = 24;
const uint SPHERE_VERTEX_COUNT = SPHERE_SEGMENTS * SPHERE_RINGS * 6;
const uint TEX_SIZE = 32;
const uint TEXTURE_COUNT = 2;
const float GRID_SPACING = 2.2f;
const float SPHERE_RADIUS = 0.9f;

fn float[<3>] sphere_point(uint segment, uint ring) {
    float theta = (float)ring / SPHERE_RINGS * (float)math::PI;
    float phi = (float)segment / SPHERE_SEGMENTS * 2.0f * (float)math::PI;
    return {
        math::sin(theta) * math::cos(phi),
        math::cos(theta),
        math::sin(theta) * math::sin(phi),
    };
}

<* Two vec4s per vertex: unit-sphere position + u, normal + v. UVs come from
   the grid indices, not atan on the position: monotonic u has no wrap seam
   and pole vertices keep their column's u instead of collapsing to one value. *>
fn void write_sphere_vertices(float* out) {
    usz cursor = 0;
    for (uint ring = 0; ring < SPHERE_RINGS; ring++) {
        for (uint segment = 0; segment < SPHERE_SEGMENTS; segment++) {
            uint[<2>][6] corners = {
                { segment, ring },
                { segment + 1, ring },
                { segment + 1, ring + 1 },
                { segment, ring },
                { segment + 1, ring + 1 },
                { segment, ring + 1 },
            };
            foreach (c : corners) {
                float[<3>] p = sphere_point(c[0], c[1]);
                out[cursor++] = p[0];
                out[cursor++] = p[1];
                out[cursor++] = p[2];
                out[cursor++] = (float)c[0] / SPHERE_SEGMENTS;
                out[cursor++] = p[0];
                out[cursor++] = p[1];
                out[cursor++] = p[2];
                out[cursor++] = (float)c[1] / SPHERE_RINGS;
            }
        }
    }
}

fn void write_instances(SphereInstance* out) {
    float half = (GRID - 1) * GRID_SPACING * 0.5f;
    for (uint row = 0; row < GRID; row++) {
        for (uint col = 0; col < GRID; col++) {
            uint i = row * GRID + col;
            out[i] = {
                .pos_scale = {
                    (float)col * GRID_SPACING - half,
                    (float)row * GRID_SPACING - half,
                    0.0f,
                    SPHERE_RADIUS,
                },
                .material = (MaterialIndex)i,
            };
        }
    }
}

fn void write_materials(Material* out, gpu::TextureIndex white, gpu::TextureIndex checker) {
    for (uint row = 0; row < GRID; row++) {
        for (uint col = 0; col < GRID; col++) {
            uint i = row * GRID + col;
            bool checkered = (row + col) % 3 == 0;
            out[i] = {
                .base_color = { 0.85f, 0.35f, 0.25f, 1.0f },
                .roughness  = 0.05f + 0.95f * (float)col / (GRID - 1),
                .metallic   = (float)row / (GRID - 1),
                .albedo_tex = checkered ? checker : white,
            };
        }
    }
}

<* Texel values are linear (the format is UNORM, sampled as-is by a shader
   that lights in linear space): 46/255 displays as roughly half brightness. *>
fn void write_texels(char* out, bool checkered) {
    for (uint y = 0; y < TEX_SIZE; y++) {
        for (uint x = 0; x < TEX_SIZE; x++) {
            bool dark = checkered && ((x / 4) + (y / 4)) % 2 == 0;
            char* texel = &out[(y * TEX_SIZE + x) * 4];
            texel[0] = dark ? (char)46 : (char)255;
            texel[1] = dark ? (char)46 : (char)255;
            texel[2] = dark ? (char)46 : (char)255;
            texel[3] = (char)255;
        }
    }
}

fn void write_matrix(gpu::Vec4f* columns, sample_camera::Mat4 m) {
    for (uint c = 0; c < 4; c++) {
        columns[c] = { m[c * 4], m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3] };
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
        .debug_name = "pbr_depth",
    };
    return gpu::create_texture(device, &desc);
}

fn gpu::TextureUse? swapchain_texture_use(gpu::TextureLayout layout) {
    switch (layout) {
        case gpu::TextureLayout.UNDEFINED: return gpu::TextureUse.UNDEFINED;
        case gpu::TextureLayout.PRESENT:   return gpu::TextureUse.PRESENT;
        default:                           return gpu::INVALID_RESOURCE_STATE~;
    }
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("pbr_materials: FAIL (%s)", err);
        return 1;
    }
    io::printn("pbr_materials: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l PBR materials", 1024, 700)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::RuntimeDesc runtime_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "pbr_materials",
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
        .debug_name       = "pbr_swapchain",
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
        .size        = SPHERE_VERTEX_COUNT * 32,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .access      = { .graphics },
        .debug_name  = "sphere_vertices",
    };
    gpu::BufferHandle vertices = gpu::create_buffer(&device, &vertex_desc)!;
    defer (void)gpu::destroy_buffer(&device, vertices);
    gpu::GpuSpan vertex_span = gpu::get_buffer_span(&device, vertices)!;
    write_sphere_vertices((float*)vertex_span.cpu);
    gpu::flush_buffer(&device, vertices, 0, 0)!;

    gpu::TextureHandle[TEXTURE_COUNT] textures;
    gpu::TextureIndex[TEXTURE_COUNT] texture_indices;
    for (uint i = 0; i < TEXTURE_COUNT; i++) {
        gpu::TextureDesc tex_desc = {
            .dimension  = gpu::TextureDimension.TEX_2D,
            .width      = TEX_SIZE,
            .height     = TEX_SIZE,
            .format     = gpu::Format.RGBA8_UNORM,
            .usage      = { .sampled, .transfer_dst },
            .access     = { .graphics },
            .debug_name = i == 0 ? (ZString)"albedo_white" : (ZString)"albedo_checker",
        };
        textures[i] = gpu::create_texture(&device, &tex_desc)!;
        texture_indices[i] = gpu::create_texture_descriptor(&device, textures[i], null)!;
    }
    defer {
        for (uint i = 0; i < TEXTURE_COUNT; i++) {
            (void)gpu::destroy_texture_descriptor(&device, texture_indices[i]);
            (void)gpu::destroy_texture(&device, textures[i]);
        }
    }

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .address_u  = gpu::AddressMode.REPEAT,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex albedo_sampler = gpu::create_sampler(&device, &sampler_desc)!;
    defer (void)gpu::destroy_sampler(&device, albedo_sampler);

    gpu::BufferDesc staging_desc = {
        .size        = TEXTURE_COUNT * TEX_SIZE * TEX_SIZE * 4,
        .usage       = { .transfer_src },
        .memory_kind = gpu::MemoryKind.STAGING,
        .access      = { .graphics },
        .debug_name  = "albedo_staging",
    };
    gpu::BufferHandle staging = gpu::create_buffer(&device, &staging_desc)!;
    defer (void)gpu::destroy_buffer(&device, staging);
    gpu::GpuSpan staging_span = gpu::get_buffer_span(&device, staging)!;
    write_texels((char*)staging_span.cpu, false);
    write_texels((char*)staging_span.cpu + TEX_SIZE * TEX_SIZE * 4, true);
    gpu::flush_buffer(&device, staging, 0, 0)!;

    gpu::BufferDesc instances_desc = {
        .size        = GRID * GRID * SphereInstance::size,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .access      = { .graphics },
        .debug_name  = "sphere_instances",
    };
    gpu::BufferHandle instances = gpu::create_buffer(&device, &instances_desc)!;
    defer (void)gpu::destroy_buffer(&device, instances);
    gpu::GpuSpan instances_span = gpu::get_buffer_span(&device, instances)!;
    write_instances((SphereInstance*)instances_span.cpu);
    gpu::flush_buffer(&device, instances, 0, 0)!;

    gpu::BufferDesc materials_desc = {
        .size        = MATERIAL_COUNT * Material::size,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .access      = { .graphics },
        .debug_name  = "material_table",
    };
    gpu::BufferHandle materials = gpu::create_buffer(&device, &materials_desc)!;
    defer (void)gpu::destroy_buffer(&device, materials);
    gpu::GpuSpan materials_span = gpu::get_buffer_span(&device, materials)!;
    write_materials((Material*)materials_span.cpu, texture_indices[0], texture_indices[1]);
    gpu::flush_buffer(&device, materials, 0, 0)!;

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = PBR_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle vert = gpu::create_shader(&device, &vert_sd)!;
    defer (void)gpu::destroy_shader(&device, vert);
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = PBR_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle frag = gpu::create_shader(&device, &frag_sd)!;
    defer (void)gpu::destroy_shader(&device, frag);

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .raster          = { .cull_mode = gpu::CullMode.BACK },
        .depth           = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.LESS },
        .color_formats   = color_formats[..],
        .depth_format    = gpu::Format.D32_FLOAT,
        .debug_name      = "pbr_forward",
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

    sample_camera::OrbitCamera camera = { .yaw = 0.0f, .pitch = 0.0f, .radius = 22.0f, .target = { 0, 0, 0 } };
    sample_camera::Mat4 view_proj;

    bool textures_uploaded = false;
    bool depth_fresh = true;
    long frame = 0;
    bool running = true;
    gpu::CompletionPoint last_graphics;
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
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
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
        width = swapchain_info.width;
        height = swapchain_info.height;
        view_proj = sample_camera::mul(
            sample_camera::perspective(0.8f, (float)width / (float)height, 0.1f, 100.0f),
            camera.view());

        gpu::FrameToken frame_token = gpu::begin_frame(&device)!;

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(&device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            gpu::end_frame(&frame_token)!;
            continue;
        }

        gpu::GpuSpan root_span = gpu::alloc_frame_span(&frame_token, PbrRoot::size, 16)!;
        PbrRoot* root = (PbrRoot*)root_span.cpu;
        write_matrix(&root.view_proj_c0, view_proj);
        float[<3>] cam_pos = camera.position();
        root.camera_pos     = { cam_pos[0], cam_pos[1], cam_pos[2], 1.0f };
        root.vertex_gpu     = vertex_span.gpu;
        root.instances_gpu  = instances_span.gpu;
        root.materials_gpu  = materials_span.gpu;
        root.albedo_sampler = albedo_sampler;

        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;

        if (!textures_uploaded) {
            for (uint i = 0; i < TEXTURE_COUNT; i++) {
                gpu::TextureBarrier to_dst = {
                    .texture       = textures[i],
                    .before_stage  = gpu::Stage.HOST,
                    .after_stage   = gpu::Stage.TRANSFER,
                    .before_hazard = gpu::Hazard.HOST_WRITE,
                    .after_hazard  = gpu::Hazard.TRANSFER_WRITE,
                    .old_layout    = gpu::TextureLayout.UNDEFINED,
                    .new_layout    = gpu::TextureLayout.TRANSFER_DST,
                };
                gpu::cmd_texture_barrier(&cmd, &to_dst)!;
                usz byte_offset = (usz)i * TEX_SIZE * TEX_SIZE * 4;
                gpu::GpuSpan slice = {
                    .gpu    = (gpu::GpuAddress)((ulong)staging_span.gpu + byte_offset),
                    .cpu    = (char*)staging_span.cpu + byte_offset,
                    .size   = TEX_SIZE * TEX_SIZE * 4,
                    .buffer = staging_span.buffer,
                    .offset = staging_span.offset + byte_offset,
                    .kind   = staging_span.kind,
                };
                gpu::BufferTextureCopyDesc upload = { .src = slice, .texture = textures[i] };
                gpu::cmd_copy_buffer_to_texture(&cmd, &upload)!;
                gpu::TextureBarrier to_read = {
                    .texture       = textures[i],
                    .before_stage  = gpu::Stage.TRANSFER,
                    .after_stage   = gpu::Stage.FRAGMENT_SHADER,
                    .before_hazard = gpu::Hazard.TRANSFER_WRITE,
                    .after_hazard  = gpu::Hazard.SHADER_READ,
                    .old_layout    = gpu::TextureLayout.TRANSFER_DST,
                    .new_layout    = gpu::TextureLayout.SHADER_READ,
                };
                gpu::cmd_texture_barrier(&cmd, &to_read)!;
            }
            textures_uploaded = true;
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
            // Pre-encoded: the clear bypasses the shader's gamma path.
            .clear    = { .rgba = { 0.16f, 0.17f, 0.20f, 1.0f } },
        }};
        gpu::DepthTargetDesc depth_target = {
            .texture  = depth,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc pass = { .colors = colors[..], .depth = &depth_target, .width = width, .height = height };
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::cmd_draw(
            commands:       &cmd,
            pipeline:       pipeline,
            vertex_root:    root_span.gpu,
            fragment_root:  root_span.gpu,
            vertex_count:   SPHERE_VERTEX_COUNT,
            instance_count: GRID * GRID,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = gpu::texture_transition(
            texture: acquired.texture,
            before:  gpu::TextureUse.COLOR_ATTACHMENT,
            after:   gpu::TextureUse.PRESENT,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_present)!;
        gpu::ExecutableCommandList cmd_executable = gpu::end_commands(&cmd)!;

        gpu::ExecutableCommandList[1] lists = { cmd_executable };
        gpu::SubmitDesc submit = { .command_lists = lists[..], .swapchain = swapchain };
        last_graphics = gpu::submit(graphics_queue, &submit)!;

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

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
}
