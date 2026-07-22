module pbr_materials;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_frame_upload;
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
        .width      = width,
        .height     = height,
        .format     = gpu::Format.D32_FLOAT,
        .usage      = { .depth_attach },
        .access     = { .graphics },
        .debug_name = "pbr_depth",
    };
    return gpu::create_texture(device, &desc);
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
        .backend                      = gpu::BackendKind.VULKAN,
        .contract_validation          = gpu::ContractValidation.FULL,
        .track_resource_lifetimes     = true,
        .enable_vulkan_validation     = true,
        .application_name             = "pbr_materials",
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
            slot_capacity: PbrRoot::size,
            access:        upload_access,
            debug_name:    "pbr_root_upload",
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
        .debug_name       = "pbr_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);

    gpu::TextureHandle depth;
    gpu::AttachmentViewHandle depth_view;
    uint depth_width;
    uint depth_height;
    bool depth_valid = false;
    if (!swapchain_info.dormant) {
        depth = create_depth_texture(&device, swapchain_info.width, swapchain_info.height)!;
        {
            defer catch (void)gpu::destroy_texture(&device, depth);
            gpu::AttachmentViewDesc depth_view_desc = { .texture = depth };
            depth_view = gpu::create_attachment_view(&device, &depth_view_desc)!;
        }
        depth_width = swapchain_info.width;
        depth_height = swapchain_info.height;
        depth_valid = true;
    }
    defer {
        if (depth_valid) {
            (void)gpu::destroy_attachment_view(&device, depth_view);
            (void)gpu::destroy_texture(&device, depth);
        }
    }

    gpu::AllocationDesc vertex_desc = {
        .size         = SPHERE_VERTEX_COUNT * 32,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "sphere_vertices",
    };
    gpu::GpuAllocation vertex_allocation = gpu::allocate_memory(&device, &vertex_desc)!;
    defer (void)gpu::free_allocation(&device, &vertex_allocation);
    gpu::GpuSpan vertex_span = gpu::get_allocation_span(&device, vertex_allocation)!;
    write_sphere_vertices((float*)gpu::get_span_mapping(&device, vertex_span)!.ptr);
    gpu::flush_mapped_span(&device, vertex_span)!;
    gpu::GpuAddress vertex_address = gpu::get_span_address(&device, vertex_span)!;

    gpu::TextureHandle[TEXTURE_COUNT] textures;
    gpu::TextureView[TEXTURE_COUNT] texture_views;
    gpu::TextureIndex[TEXTURE_COUNT] texture_indices;
    for (uint i = 0; i < TEXTURE_COUNT; i++) {
        gpu::TextureDesc tex_desc = {
            .width      = TEX_SIZE,
            .height     = TEX_SIZE,
            .format     = gpu::Format.RGBA8_UNORM,
            .usage      = { .sampled, .transfer_dst },
            .access     = { .graphics },
            .debug_name = i == 0 ? (ZString)"albedo_white" : (ZString)"albedo_checker",
        };
        textures[i] = gpu::create_texture(&device, &tex_desc)!;
        texture_views[i] = gpu::create_texture_view(&device, textures[i], null)!;
        texture_indices[i] = texture_views[i].index;
    }
    defer {
        for (uint i = 0; i < TEXTURE_COUNT; i++) {
            (void)gpu::destroy_texture_view(&device, texture_views[i]);
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
    gpu::SamplerIndex albedo_sampler = gpu::intern_sampler(&device, &sampler_desc)!;

    gpu::AllocationDesc staging_desc = {
        .size         = TEXTURE_COUNT * TEX_SIZE * TEX_SIZE * 4,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "albedo_staging",
    };
    gpu::GpuAllocation staging_allocation = gpu::allocate_memory(&device, &staging_desc)!;
    defer (void)gpu::free_allocation(&device, &staging_allocation);
    gpu::GpuSpan staging_span = gpu::get_allocation_span(&device, staging_allocation)!;
    char* staging_texels = (char*)gpu::get_span_mapping(&device, staging_span)!.ptr;
    write_texels(staging_texels, false);
    write_texels(staging_texels + TEX_SIZE * TEX_SIZE * 4, true);
    gpu::flush_mapped_span(&device, staging_span)!;

    gpu::AllocationDesc instances_desc = {
        .size         = GRID * GRID * SphereInstance::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "sphere_instances",
    };
    gpu::GpuAllocation instances_allocation = gpu::allocate_memory(&device, &instances_desc)!;
    defer (void)gpu::free_allocation(&device, &instances_allocation);
    gpu::GpuSpan instances_span = gpu::get_allocation_span(&device, instances_allocation)!;
    write_instances((SphereInstance*)gpu::get_span_mapping(&device, instances_span)!.ptr);
    gpu::flush_mapped_span(&device, instances_span)!;
    gpu::GpuAddress instances_address = gpu::get_span_address(&device, instances_span)!;

    gpu::AllocationDesc materials_desc = {
        .size         = MATERIAL_COUNT * Material::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "material_table",
    };
    gpu::GpuAllocation materials_allocation = gpu::allocate_memory(&device, &materials_desc)!;
    defer (void)gpu::free_allocation(&device, &materials_allocation);
    gpu::GpuSpan materials_span = gpu::get_allocation_span(&device, materials_allocation)!;
    Material* material_data = (Material*)gpu::get_span_mapping(&device, materials_span)!.ptr;
    write_materials(material_data, texture_indices[0], texture_indices[1]);
    gpu::flush_mapped_span(&device, materials_span)!;
    gpu::GpuAddress materials_address = gpu::get_span_address(&device, materials_span)!;

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = PBR_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode vert = gpu::prepare_shader_code(&vert_sd)!;
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = PBR_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode frag = gpu::prepare_shader_code(&frag_sd)!;

    gpu::ColorTargetState[1] color_targets = {{
        .format     = swapchain_info.format,
        .write_mask = gpu::COLOR_WRITE_ALL,
    }};
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .colors          = color_targets[..],
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

        bool pipeline_changed = !pipeline_valid || color_targets[0].format != swapchain_info.format;
        bool depth_changed = !depth_valid
            || depth_width != swapchain_info.width
            || depth_height != swapchain_info.height;
        if (pipeline_changed || depth_changed) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
        }
        if (pipeline_changed) {
            if (pipeline_valid) gpu::destroy_pipeline(&device, pipeline)!;
            pipeline_valid = false;
            color_targets[0].format = swapchain_info.format;
            pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
            pipeline_valid = true;
        }
        if (depth_changed) {
            if (depth_valid) {
                gpu::destroy_attachment_view(&device, depth_view)!;
                gpu::destroy_texture(&device, depth)!;
            }
            depth_valid = false;
            depth = create_depth_texture(&device, swapchain_info.width, swapchain_info.height)!;
            {
                defer catch (void)gpu::destroy_texture(&device, depth);
                gpu::AttachmentViewDesc depth_view_desc = { .texture = depth };
                depth_view = gpu::create_attachment_view(&device, &depth_view_desc)!;
            }
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
        gpu::GpuSpan root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      PbrRoot::size,
            alignment: 16,
        )!;
        PbrRoot* root = (PbrRoot*)gpu::get_span_mapping(&device, root_span)!.ptr;
        write_matrix(&root.view_proj_c0, view_proj);
        float[<3>] cam_pos = camera.position();
        root.camera_pos     = { cam_pos[0], cam_pos[1], cam_pos[2], 1.0f };
        root.vertex_gpu     = vertex_address;
        root.instances_gpu  = instances_address;
        root.materials_gpu  = materials_address;
        root.albedo_sampler = albedo_sampler;
        gpu::GpuAddress root_address = gpu::get_span_address(&device, root_span)!;
        sample_frame_upload::flush_frame_upload(&upload_batch)!;

        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
        defer (void)gpu::discard_commands(&cmd);

        if (!textures_uploaded) {
            for (uint i = 0; i < TEXTURE_COUNT; i++) {
                gpu::TextureBarrier to_dst = {
                    .texture = textures[i],
                    .before  = { .layout = gpu::TextureLayout.UNDEFINED },
                    .after   = {
                        .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                        .stages = { .transfer },
                        .access = { .write },
                    },
                };
                gpu::cmd_texture_barrier(&cmd, &to_dst)!;
                usz byte_offset = (usz)i * TEX_SIZE * TEX_SIZE * 4;
                gpu::GpuSpan slice = staging_span.checked_subspan(byte_offset, TEX_SIZE * TEX_SIZE * 4)!;
                gpu::BufferTextureCopyDesc upload = { .src = slice, .texture = textures[i] };
                gpu::cmd_copy_buffer_to_texture(&cmd, &upload)!;
                gpu::TextureBarrier to_read = {
                    .texture = textures[i],
                    .before  = {
                        .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                        .stages = { .transfer },
                        .access = { .write },
                    },
                    .after   = gpu::sampled_at({ .fragment_shader }),
                };
                gpu::cmd_texture_barrier(&cmd, &to_read)!;
            }
            textures_uploaded = true;
        }

        if (depth_fresh) {
            gpu::TextureBarrier depth_init = {
                .texture = depth,
                .before  = { .layout = gpu::TextureLayout.UNDEFINED },
                .after   = {
                    .layout = gpu::TextureLayout.DEPTH_ATTACHMENT,
                    .stages = { .depth_output },
                    .access = { .read, .write },
                },
            };
            gpu::cmd_texture_barrier(&cmd, &depth_init)!;
            depth_fresh = false;
        }

        gpu::TextureBarrier to_attach = gpu::texture_transition(
            texture: acquired.texture,
            before:  acquired.prior_state,
            after:   {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_attach)!;

        gpu::ColorTargetDesc[1] colors = {{
            .view     = color_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            // Pre-encoded: the clear bypasses the shader's gamma path.
            .clear    = { .rgba = { 0.16f, 0.17f, 0.20f, 1.0f } },
        }};
        gpu::DepthTargetDesc depth_target = {
            .view     = depth_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .depth = 1.0f },
        };
        gpu::RenderPassDesc pass = { .colors = colors[..], .depth = &depth_target, .width = width, .height = height };
        gpu::cmd_bind_pipeline(&cmd, pipeline)!;
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::DynamicRasterState raster_state = {
            .cull_mode = gpu::CullMode.BACK,
        };
        gpu::cmd_set_raster_state(&cmd, &raster_state)!;
        gpu::DepthState depth_state = {
            .test_enable  = true,
            .write_enable = true,
            .compare      = gpu::CompareOp.LESS,
        };
        gpu::cmd_set_depth_state(&cmd, &depth_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    root_address,
            fragment_root:  root_address,
            vertex_count:   SPHERE_VERTEX_COUNT,
            instance_count: GRID * GRID,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = gpu::texture_transition(
            texture: acquired.texture,
            before:  {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
            after:   {
                .layout = gpu::TextureLayout.PRESENT,
            },
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
                from_state:  {
                    .layout = gpu::TextureLayout.PRESENT,
                },
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
