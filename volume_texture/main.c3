module volume_texture;

import gpu;
import sample_args;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;
import std::math;

faultdef VOLUME_TEXTURE_UNSUPPORTED;

const char[*] VOLUME_VERT_SPIRV = $embed("shaders/volume.vert.spv");
const char[*] VOLUME_FRAG_SPIRV = $embed("shaders/volume.frag.spv");

const uint VOLUME_SIZE = 48;
const usz VOLUME_BYTES = (usz)VOLUME_SIZE * VOLUME_SIZE * VOLUME_SIZE * 4;
const uint FULLSCREEN_VERTEX_COUNT = 3;

fn float saturate(float value) {
    if (value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

fn void write_volume(char[] texels) {
    float side = (float)VOLUME_SIZE;
    usz side_index = (usz)VOLUME_SIZE;
    for (uint z = 0; z < VOLUME_SIZE; z++) {
        for (uint y = 0; y < VOLUME_SIZE; y++) {
            for (uint x = 0; x < VOLUME_SIZE; x++) {
                float px = ((float)x + 0.5f) / side * 2.0f - 1.0f;
                float py = ((float)y + 0.5f) / side * 2.0f - 1.0f;
                float pz = ((float)z + 0.5f) / side * 2.0f - 1.0f;
                float radius = math::sqrt(px * px + py * py + pz * pz);
                float variation =
                    math::sin(px * 5.0f + pz * 3.0f) * 0.13f
                    + math::sin(py * 7.0f - px * 2.0f) * 0.09f
                    + math::sin((px + py + pz) * 9.0f) * 0.05f;
                float density = saturate((1.0f - radius) * 1.35f + variation);
                usz offset =
                    (((usz)z * side_index + y) * side_index + x) * 4;
                texels[offset] =
                    (char)(uint)(saturate(0.35f + px * 0.25f + density * 0.55f) * 255.0f);
                texels[offset + 1] =
                    (char)(uint)(saturate(0.25f + py * 0.20f + density * 0.45f) * 255.0f);
                texels[offset + 2] =
                    (char)(uint)(saturate(0.55f + pz * 0.20f + density * 0.40f) * 255.0f);
                texels[offset + 3] = (char)(uint)(density * 255.0f);
            }
        }
    }
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        if (err == VOLUME_TEXTURE_UNSUPPORTED) {
            io::printn("volume_texture: SKIP (3D RGBA8 sampling unavailable)");
            return 0;
        }
        io::printfn("volume_texture: FAIL (%s)", err);
        return 1;
    }
    io::printn("volume_texture: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window =
        sample_window::create_sample_window("gpu.c3l volume texture", 800, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::RuntimeDesc runtime_desc = {
        .contract_validation      = gpu::ContractValidation.FULL,
        .enable_vulkan_validation = true,
        .application_name         = "volume_texture",
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

    gpu::TextureDesc volume_desc = {
        .width        = VOLUME_SIZE,
        .height       = VOLUME_SIZE,
        .depth        = VOLUME_SIZE,
        .mip_levels   = 1,
        .array_layers = 1,
        .format       = gpu::Format.RGBA8_UNORM,
        .usage        = { .sampled, .transfer_dst },
        .access       = { .graphics },
        .sample_count = gpu::SampleCount.ONE,
        .debug_name   = "volume_texture",
    };
    gpu::TextureFormatSupport format_support =
        gpu::get_texture_format_support(&device, volume_desc.format)!;
    if (!format_support.features.linear_filter
        || !gpu::supports_texture_desc(&device, &volume_desc)!) {
        return VOLUME_TEXTURE_UNSUPPORTED~;
    }

    gpu::TextureRequirements requirements =
        gpu::get_texture_requirements(&device, &volume_desc)!;
    gpu::TextureRequirements[1] texture_requirements = { requirements };
    gpu::AllocationDesc texture_memory_desc = {
        .size                 = requirements.size,
        .alignment            = requirements.alignment,
        .memory_class         = gpu::MemoryClass.TEXTURE,
        .access               = volume_desc.access,
        .texture_requirements = texture_requirements[..],
        .debug_name           = "volume_texture_memory",
    };
    gpu::DedicatedTexture volume = gpu::create_dedicated_texture(
        device:          &device,
        desc:            &volume_desc,
        allocation_desc: &texture_memory_desc,
    )!;
    defer {
        (void)gpu::destroy_texture(&device, volume.texture);
        (void)gpu::free_allocation(&device, &volume.allocation);
    }
    gpu::TextureView volume_view =
        gpu::create_texture_view(&device, volume.texture, null)!;
    defer (void)gpu::destroy_texture_view(&device, volume_view);

    gpu::SamplerDesc volume_sampler_desc = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex volume_sampler =
        gpu::intern_sampler(&device, &volume_sampler_desc)!;

    {
        gpu::AllocationDesc staging_desc = {
            .size         = VOLUME_BYTES,
            .alignment    = 16,
            .memory_class = gpu::MemoryClass.CPU_WRITE,
            .access       = { .graphics },
            .debug_name   = "volume_texture_upload",
        };
        gpu::GpuAllocation staging = gpu::allocate_memory(&device, &staging_desc)!;
        defer (void)gpu::free_allocation(&device, &staging);
        gpu::GpuSpan staging_span = gpu::get_allocation_span(&device, staging)!;
        write_volume(gpu::get_span_mapping(&device, staging_span)!);
        gpu::flush_mapped_span(&device, staging_span)!;

        gpu::CommandList upload_commands = gpu::begin_commands(&graphics_allocator)!;
        defer (void)gpu::discard_commands(&upload_commands);
        gpu::TextureBarrier to_transfer = gpu::texture_transition(
            texture: volume.texture,
            before:  { .layout = gpu::TextureLayout.UNDEFINED },
            after:   {
                .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                .stages = { .transfer },
                .access = { .write },
            },
        )!;
        gpu::cmd_texture_barrier(&upload_commands, &to_transfer)!;
        gpu::BufferTextureCopyDesc copy = {
            .src         = staging_span,
            .texture     = volume.texture,
            .base_layer  = 0,
            .layer_count = 1,
            .x           = 0,
            .y           = 0,
            .z           = 0,
            .width       = VOLUME_SIZE,
            .height      = VOLUME_SIZE,
            .depth       = VOLUME_SIZE,
        };
        gpu::cmd_copy_buffer_to_texture(&upload_commands, &copy)!;
        gpu::TextureBarrier to_sample = gpu::texture_transition(
            texture: volume.texture,
            before:  {
                .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                .stages = { .transfer },
                .access = { .write },
            },
            after:   gpu::sampled_at({ .fragment_shader }),
        )!;
        gpu::cmd_texture_barrier(&upload_commands, &to_sample)!;
        gpu::ExecutableCommandList[1] upload_lists = {
            gpu::end_commands(&upload_commands)!,
        };
        defer (void)gpu::discard_executable_commands(&upload_lists[0]);
        gpu::SubmitDesc upload_submit = { .command_lists = upload_lists[..] };
        gpu::CompletionPoint upload_completion =
            gpu::submit(graphics_queue, &upload_submit)!;
        gpu::wait_completion(upload_completion)!;
    }

    uint width;
    uint height;
    sample_window::pixel_size(&window, &width, &height);
    gpu::SwapchainDesc swapchain_desc = {
        .width            = width,
        .height           = height,
        .preferred_format = gpu::Format.BGRA8_UNORM,
        .present_mode     = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX,
        .srgb             = false,
        .debug_name       = "volume_texture_swapchain",
    };
    gpu::SwapchainHandle swapchain =
        gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);

    gpu::QueueRoles upload_access = { .graphics };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        &device,
            slot_capacity: VolumeRoot::size,
            access:        upload_access,
            debug_name:    "volume_texture_frame_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::ColorTargetState[1] color_targets = {
        gpu::color_blend_disabled(),
    };
    gpu::GraphicsPipelineDesc pipeline_desc = {
        .vertex_shader   = {
            .spirv       = VOLUME_VERT_SPIRV[..],
            .entry_point = "main",
        },
        .fragment_shader = {
            .spirv       = VOLUME_FRAG_SPIRV[..],
            .entry_point = "main",
        },
        .color_formats   = color_formats[..],
        .debug_name      = "volume_texture",
    };
    gpu::PipelineHandle pipeline;
    bool pipeline_valid = false;
    if (!swapchain_info.dormant) {
        pipeline = gpu::create_graphics_pipeline(&device, &pipeline_desc)!;
        pipeline_valid = true;
    }
    defer {
        if (pipeline_valid) (void)gpu::destroy_pipeline(&device, pipeline);
    }

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
        if (!pipeline_valid || color_formats[0] != swapchain_info.format) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
            if (pipeline_valid) gpu::destroy_pipeline(&device, pipeline)!;
            pipeline_valid = false;
            color_formats[0] = swapchain_info.format;
            pipeline = gpu::create_graphics_pipeline(&device, &pipeline_desc)!;
            pipeline_valid = true;
        }

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(
            device:     &device,
            swapchain:  swapchain,
            timeout_ns: sample_window::FRAME_ACQUIRE_TIMEOUT_NS,
        );
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) {
                swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            }
            continue;
        }

        sample_frame_upload::FrameUploadBatch upload_batch =
            sample_frame_upload::begin_frame_upload(&upload_ring)!;
        defer catch {
            if (upload_batch.ring != null) {
                (void)sample_frame_upload::cancel_frame_upload(&upload_batch);
            }
        };
        gpu::CommandList commands = gpu::begin_commands(&graphics_allocator)!;
        defer (void)gpu::discard_commands(&commands);

        gpu::TextureBarrier to_attachment = gpu::texture_transition(
            texture: acquired.texture,
            before:  acquired.prior_state,
            after:   {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
        )!;
        gpu::cmd_texture_barrier(&commands, &to_attachment)!;

        gpu::GpuSpan root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      VolumeRoot::size,
            alignment: 16,
        )!;
        VolumeRoot* root =
            (VolumeRoot*)gpu::get_span_mapping(&device, root_span)!.ptr;
        root.volume_texture = volume_view.index;
        root.volume_sampler = volume_sampler;
        root.time = (float)frame / 60.0f;
        root.aspect =
            (float)swapchain_info.width / (float)swapchain_info.height;
        gpu::GpuAddress root_address = gpu::get_span_address(&device, root_span)!;

        gpu::ColorTargetDesc[1] colors = {{
            .view     = acquired.attachment_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.008f, 0.012f, 0.025f, 1.0f } },
        }};
        gpu::RenderPassDesc pass = {
            .colors = colors[..],
            .width  = swapchain_info.width,
            .height = swapchain_info.height,
        };
        gpu::GraphicsState graphics =
            gpu::render_geometry_state(pass.width, pass.height)!;
        graphics.color.targets = color_targets[..];
        gpu::cmd_begin_render_pass(&commands, &pass)!;
        gpu::cmd_bind_pipeline(&commands, pipeline)!;
        gpu::cmd_set_graphics_state(&commands, &graphics)!;
        gpu::cmd_draw(
            commands:       &commands,
            vertex_root:    root_address,
            fragment_root:  root_address,
            vertex_count:   FULLSCREEN_VERTEX_COUNT,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&commands)!;

        gpu::TextureBarrier to_present = gpu::texture_transition(
            texture: acquired.texture,
            before:  {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
            after:   { .layout = gpu::TextureLayout.PRESENT },
        )!;
        gpu::cmd_texture_barrier(&commands, &to_present)!;
        sample_frame_upload::flush_frame_upload(&upload_batch)!;
        gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&commands)! };
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
                width:               swapchain_info.width,
                height:              swapchain_info.height,
                format:              swapchain_info.format,
                from_state:  {
                    .layout = gpu::TextureLayout.PRESENT,
                },
                path: options.screenshot_path,
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
