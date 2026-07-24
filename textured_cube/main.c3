module textured_cube;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;
import std::math;

const char[*] CUBE_VERT_SPIRV = $embed("shaders/cube.vert.spv");
const char[*] CUBE_FRAG_SPIRV = $embed("shaders/cube.frag.spv");

const uint TEX_SIZE = 16;
const usz UPLOAD_BYTES_PER_SLOT = 160;

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
        .width     = width,
        .height    = height,
        .format    = gpu::Format.D32_FLOAT,
        .usage     = { .depth_attach },
        .access     = { .graphics },
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

    gpu::RuntimeDesc runtime_desc = {
        .backend                      = gpu::BackendKind.VULKAN,
        .contract_validation          = gpu::ContractValidation.TRUSTED,
        .track_resource_lifetimes     = false,
        .enable_vulkan_validation     = true,
        .application_name             = "textured_cube",
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);

    gpu::Surface surface = sample_window::create_surface(&runtime, &window)!;
    defer (void)gpu::destroy_surface(&surface);

    gpu::Device device = sample_window::create_presentation_device(&runtime, &surface)!;
    defer (void)gpu::destroy_device(&device);
    gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;
    gpu::CommandAllocator graphics_allocator =
        gpu::create_command_allocator(&device, graphics_queue)!;
    defer (void)gpu::destroy_command_allocator(&graphics_allocator);

    gpu::QueueRoles upload_access = { .graphics };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        &device,
            slot_capacity: UPLOAD_BYTES_PER_SLOT,
            access:        upload_access,
            debug_name:    "textured_cube_frame_upload",
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
        .debug_name       = "cube_swapchain",
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
        .size         = CUBE_VERTEX_BYTES,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "cube_vertices",
    };
    gpu::GpuAllocation vertices = gpu::allocate_memory(&device, &vertex_desc)!;
    defer (void)gpu::free_allocation(&device, &vertices);
    gpu::GpuSpan vertex_span = gpu::get_allocation_span(&device, vertices)!;
    write_cube_vertices((float*)gpu::get_span_mapping(&device, vertex_span)!.ptr);
    gpu::flush_mapped_span(&device, vertex_span)!;
    gpu::GpuAddress vertex_address = gpu::get_span_address(&device, vertex_span)!;

    gpu::TextureDesc tex_desc = {
        .width     = TEX_SIZE,
        .height    = TEX_SIZE,
        .format    = gpu::Format.RGBA8_UNORM,
        .usage     = { .sampled, .transfer_dst },
        .access     = { .graphics },
    };
    gpu::TextureHandle checker = gpu::create_texture(&device, &tex_desc)!;
    defer (void)gpu::destroy_texture(&device, checker);
    gpu::TextureView tex_view = gpu::create_texture_view(&device, checker, null)!;
    defer (void)gpu::destroy_texture_view(&device, tex_view);
    gpu::TextureIndex tex_index = tex_view.index;

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex smp_index = gpu::intern_sampler(&device, &sampler_desc)!;

    gpu::AllocationDesc staging_desc = {
        .size         = TEX_SIZE * TEX_SIZE * 4,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
    };
    gpu::GpuAllocation staging = gpu::allocate_memory(&device, &staging_desc)!;
    defer (void)gpu::free_allocation(&device, &staging);
    gpu::GpuSpan staging_span = gpu::get_allocation_span(&device, staging)!;
    char* texels = (char*)gpu::get_span_mapping(&device, staging_span)!.ptr;
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
    gpu::flush_mapped_span(&device, staging_span)!;

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = CUBE_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode vert = gpu::prepare_shader_code(&vert_sd)!;
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = CUBE_FRAG_SPIRV[..], .entry_point = "main" };
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

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(
            device:     &device,
            swapchain:  swapchain,
            timeout_ns: sample_window::FRAME_ACQUIRE_TIMEOUT_NS,
        );
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

        gpu::CommandList cmd = gpu::begin_commands(&graphics_allocator)!;
        defer (void)gpu::discard_commands(&cmd);

        if (!checker_uploaded) {
            gpu::TextureBarrier to_dst = {
                .texture = checker,
                .before  = { .layout = gpu::TextureLayout.UNDEFINED },
                .after   = {
                    .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                    .stages = { .transfer },
                    .access = { .write },
                },
            };
            gpu::cmd_texture_barrier(&cmd, &to_dst);
            gpu::BufferTextureCopyDesc upload = { .src = staging_span, .texture = checker };
            gpu::cmd_copy_buffer_to_texture(&cmd, &upload);
            gpu::TextureBarrier to_read = {
                .texture = checker,
                .before  = {
                    .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                    .stages = { .transfer },
                    .access = { .write },
                },
                .after   = gpu::sampled_at({ .fragment_shader }),
            };
            gpu::cmd_texture_barrier(&cmd, &to_read);
            checker_uploaded = true;
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
            gpu::cmd_texture_barrier(&cmd, &depth_init);
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
        gpu::cmd_texture_barrier(&cmd, &to_attach);

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

        gpu::GpuSpan root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      SceneRoot::size,
            alignment: 16,
        )!;
        SceneRoot* root = (SceneRoot*)gpu::get_span_mapping(&device, root_span)!.ptr;
        write_matrix(&root.view_proj_c0, view_proj);
        write_matrix(&root.model_c0, spin_model(time));
        root.vertex_gpu     = vertex_address;
        root.albedo_texture = tex_index;
        root.albedo_sampler = smp_index;
        root.time           = time;
        gpu::GpuAddress root_address = gpu::get_span_address(&device, root_span)!;

        gpu::ColorTargetDesc[1] colors = {{
            .view     = color_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.06f, 0.07f, 0.11f, 1.0f } },
        }};
        gpu::DepthTargetDesc depth_target = {
            .view     = depth_view,
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
        gpu::GraphicsState graphics =
            gpu::full_render_graphics_state(pass.width, pass.height)!;
        graphics.depth = {
            .test_enable  = true,
            .write_enable = true,
            .compare      = gpu::CompareOp.LESS,
        };
        gpu::cmd_bind_pipeline(&cmd, pipeline);
        gpu::cmd_begin_render_pass_with_state(&cmd, &pass, &graphics);
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    root_address,
            fragment_root:  root_address,
            vertex_count:   CUBE_VERTEX_COUNT,
            instance_count: 1,
        );
        gpu::cmd_end_render_pass(&cmd);

        gpu::TextureBarrier to_present = {
            .texture = acquired.texture,
            .before  = {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
            .after   = {
                .layout = gpu::TextureLayout.PRESENT,
            },
        };
        gpu::cmd_texture_barrier(&cmd, &to_present);

        sample_frame_upload::flush_frame_upload(&upload_batch)!;
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
                allocator:           &graphics_allocator,
                producer_completion: last_graphics,
                src:                 acquired.texture,
                width:       swapchain_info.width,
                height:      swapchain_info.height,
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
