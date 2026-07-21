module texture_filtering;

import gpu;
import sample_attachment_views;
import sample_args;
import sample_camera;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;

const char[*] PLANE_VERT_SPIRV = $embed("shaders/plane.vert.spv");
const char[*] PLANE_FRAG_SPIRV = $embed("shaders/plane.frag.spv");

const uint TEX_SIZE = 256;
const uint MIP_LEVELS = 9;
const uint CHECKER_CELLS = 8;
const usz UPLOAD_BYTES_PER_SLOT = 112;

const uint PLANE_VERTEX_COUNT = 6;
const usz  PLANE_VERTEX_BYTES = PLANE_VERTEX_COUNT * 32;
const float PLANE_EXTENT = 220.0f;
const float UV_TILES = 80.0f;

// One tint per mip level so LOD selection reads as color bands.
const float[<3>][MIP_LEVELS] MIP_TINTS = {
    { 1.00, 1.00, 1.00 },
    { 1.00, 0.45, 0.45 },
    { 1.00, 0.70, 0.35 },
    { 1.00, 1.00, 0.40 },
    { 0.45, 1.00, 0.45 },
    { 0.40, 1.00, 1.00 },
    { 0.45, 0.55, 1.00 },
    { 0.75, 0.45, 1.00 },
    { 1.00, 0.45, 1.00 },
};

<* The analytic box-filter result for an axis-aligned checker: each level is
   the same CHECKER_CELLS-across grid at its own resolution, tinted. *>
fn void write_mip_pixels(char[] out, uint level_size, uint level) {
    float[<3>] tint = MIP_TINTS[level];
    uint cell = level_size / CHECKER_CELLS;
    for (uint y = 0; y < level_size; y++) {
        for (uint x = 0; x < level_size; x++) {
            bool checkered = cell == 0 || ((x / cell) + (y / cell)) % 2 == 0;
            float base = checkered ? 235.0f : 45.0f;
            usz i = ((usz)y * level_size + x) * 4;
            out[i]     = (char)(base * tint[0]);
            out[i + 1] = (char)(base * tint[1]);
            out[i + 2] = (char)(base * tint[2]);
            out[i + 3] = (char)255;
        }
    }
}

fn void write_plane_vertices(float* out) {
    float e = PLANE_EXTENT;
    float t = UV_TILES;
    float[<4>][12] data = {
        { -e, 0, e, 0 },  { 0, t, 0, 0 },
        { e, 0, e, 0 },   { t, t, 0, 0 },
        { e, 0, -e, 0 },  { t, 0, 0, 0 },
        { -e, 0, e, 0 },  { 0, t, 0, 0 },
        { e, 0, -e, 0 },  { t, 0, 0, 0 },
        { -e, 0, -e, 0 }, { 0, 0, 0, 0 },
    };
    for (uint i = 0; i < 12; i++) {
        for (uint c = 0; c < 4; c++) out[i * 4 + c] = data[i][c];
    }
}

fn void write_matrix(gpu::Vec4f* columns, sample_camera::Mat4 m) {
    for (uint c = 0; c < 4; c++) {
        columns[c] = { m[c * 4], m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3] };
    }
}

fn gpu::SamplerIndex? make_sampler(gpu::Device* device, gpu::Filter filter, gpu::Filter mip_filter, float max_lod, bool aniso = false) {
    gpu::SamplerDesc desc = {
        .min_filter        = filter,
        .mag_filter        = filter,
        .mip_filter        = mip_filter,
        .address_u         = gpu::AddressMode.REPEAT,
        .address_v         = gpu::AddressMode.REPEAT,
        .address_w         = gpu::AddressMode.REPEAT,
        .max_lod           = max_lod,
        .anisotropy_enable = aniso,
        .max_anisotropy    = aniso ? 16.0f : 0.0f,
    };
    gpu::Sampler sampler = gpu::intern_sampler(device, &desc)!;
    return gpu::publish_sampler(device, sampler);
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("texture_filtering: FAIL (%s)", err);
        return 1;
    }
    io::printn("texture_filtering: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l texture filtering", 1024, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::RuntimeDesc runtime_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "texture_filtering",
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);

    gpu::Surface surface = sample_window::create_surface(&runtime, &window)!;
    defer (void)gpu::destroy_surface(&surface);

    gpu::Device device = sample_window::create_presentation_device(&runtime, &surface)!;
    defer (void)gpu::destroy_device(&device);
    gpu::DeviceCaps caps = gpu::get_device_caps(&device)!;

    gpu::QueueRoles upload_access = { .graphics };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        &device,
            slot_capacity: UPLOAD_BYTES_PER_SLOT,
            access:        upload_access,
            debug_name:    "texture_filtering_frame_upload",
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
        .debug_name       = "filtering_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);
    sample_attachment_views::AttachmentViewCache attachment_views =
        sample_attachment_views::create_attachment_view_cache(
            &device,
            swapchain_info.image_count,
        )!;
    defer (void)sample_attachment_views::destroy_attachment_view_cache(
        &attachment_views,
    );

    gpu::AllocationDesc vertex_desc = {
        .size         = PLANE_VERTEX_BYTES,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "plane_vertices",
    };
    gpu::GpuAllocation vertices = gpu::allocate_memory(&device, &vertex_desc)!;
    defer (void)gpu::free_allocation(&device, &vertices);
    gpu::GpuSpan vertex_span = gpu::get_allocation_span(&device, vertices)!;
    write_plane_vertices((float*)gpu::get_span_mapping(&device, vertex_span)!.ptr);
    gpu::flush_mapped_span(&device, vertex_span)!;
    gpu::GpuAddress vertex_address = gpu::get_span_address(&device, vertex_span)!;

    gpu::TextureDesc tex_desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = TEX_SIZE,
        .height     = TEX_SIZE,
        .mip_levels = MIP_LEVELS,
        .format     = gpu::Format.RGBA8_UNORM,
        .usage      = { .sampled, .transfer_dst },
        .access     = { .graphics },
        .debug_name = "tinted_checker",
    };
    gpu::TextureHandle checker = gpu::create_texture(&device, &tex_desc)!;
    defer (void)gpu::destroy_texture(&device, checker);

    {
        usz mip_upload_bytes = 0;
        for (uint level = 0; level < MIP_LEVELS; level++) {
            uint level_size = TEX_SIZE >> level;
            if (level_size == 0) level_size = 1;
            mip_upload_bytes += (usz)level_size * level_size * 4;
        }

        gpu::AllocationDesc mip_upload_desc = {
            .size         = mip_upload_bytes,
            .alignment    = 16,
            .memory_class = gpu::MemoryClass.CPU_WRITE,
            .access       = { .graphics },
            .debug_name   = "texture_filtering_mip_upload",
        };
        gpu::GpuAllocation mip_upload = gpu::allocate_memory(&device, &mip_upload_desc)!;
        defer (void)gpu::free_allocation(&device, &mip_upload);
        gpu::GpuSpan mip_upload_span = gpu::get_allocation_span(&device, mip_upload)!;

        usz byte_offset = 0;
        for (uint level = 0; level < MIP_LEVELS; level++) {
            uint level_size = TEX_SIZE >> level;
            if (level_size == 0) level_size = 1;
            usz level_bytes = (usz)level_size * level_size * 4;
            gpu::GpuSpan level_span =
                mip_upload_span.checked_subspan(byte_offset, level_bytes)!;
            write_mip_pixels(
                gpu::get_span_mapping(&device, level_span)!,
                level_size,
                level,
            );
            byte_offset += level_bytes;
        }
        gpu::flush_mapped_span(&device, mip_upload_span)!;

        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;
        gpu::CommandList upload_commands = gpu::begin_commands(graphics_queue)!;
        defer (void)gpu::discard_commands(&upload_commands);
        gpu::TextureBarrier to_transfer = gpu::texture_transition(
            texture: checker,
            before:  gpu::TextureUse.UNDEFINED,
            after:   gpu::TextureUse.TRANSFER_DESTINATION,
        )!;
        gpu::cmd_texture_barrier(&upload_commands, &to_transfer)!;

        byte_offset = 0;
        for (uint level = 0; level < MIP_LEVELS; level++) {
            uint level_size = TEX_SIZE >> level;
            if (level_size == 0) level_size = 1;
            usz level_bytes = (usz)level_size * level_size * 4;
            gpu::BufferTextureCopyDesc copy = {
                .src     = mip_upload_span.checked_subspan(byte_offset, level_bytes)!,
                .texture = checker,
                .mip     = level,
            };
            gpu::cmd_copy_buffer_to_texture(&upload_commands, &copy)!;
            byte_offset += level_bytes;
        }

        gpu::TextureBarrier to_sample = gpu::texture_transition(
            texture: checker,
            before:  gpu::TextureUse.TRANSFER_DESTINATION,
            after:   gpu::TextureUse.SAMPLED_FRAGMENT,
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
    gpu::TextureView tex_view = gpu::create_texture_view(&device, checker, null)!;
    defer (void)gpu::destroy_texture_view(&device, tex_view);
    gpu::TextureIndex tex_index = tex_view.index;

    gpu::SamplerIndex nearest_smp = make_sampler(
        device:     &device,
        filter:     gpu::Filter.NEAREST,
        mip_filter: gpu::Filter.NEAREST,
        max_lod:    0.0f,
    )!;
    gpu::SamplerIndex bilinear_smp = make_sampler(
        device:     &device,
        filter:     gpu::Filter.LINEAR,
        mip_filter: gpu::Filter.NEAREST,
        max_lod:    0.0f,
    )!;
    gpu::SamplerIndex trilinear_smp = make_sampler(
        device:     &device,
        filter:     gpu::Filter.LINEAR,
        mip_filter: gpu::Filter.LINEAR,
        max_lod:    (float)MIP_LEVELS,
    )!;
    gpu::SamplerIndex aniso_smp = make_sampler(
        device:     &device,
        filter:     gpu::Filter.LINEAR,
        mip_filter: gpu::Filter.LINEAR,
        max_lod:    (float)MIP_LEVELS,
        aniso:      caps.max_sampler_anisotropy > 0,
    )!;

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = PLANE_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode vert = gpu::prepare_shader_code(&vert_sd)!;
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = PLANE_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode frag = gpu::prepare_shader_code(&frag_sd)!;

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .color_formats   = color_formats[..],
        .debug_name      = "texture_filtering",
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
            swapchain_info = sample_window::recover_swapchain(
                device:           &device,
                swapchain:        swapchain,
                sample:           &window,
                attachment_views: &attachment_views,
            )!;
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
            pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
            pipeline_valid = true;
        }

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(&device, swapchain);
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) {
                swapchain_info = sample_window::recover_swapchain(
                    device:           &device,
                    swapchain:        swapchain,
                    sample:           &window,
                    attachment_views: &attachment_views,
                )!;
            }
            continue;
        }

        gpu::AttachmentViewHandle color_view =
            sample_attachment_views::attachment_view_for(
                &attachment_views,
                acquired,
            )!;

        sample_frame_upload::FrameUploadBatch upload_batch =
            sample_frame_upload::begin_frame_upload(&upload_ring)!;
        defer catch {
            if (upload_batch.ring != null) {
                (void)sample_frame_upload::cancel_frame_upload(&upload_batch);
            }
        };

        gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
        defer (void)gpu::discard_commands(&cmd);

        gpu::TextureUse swapchain_before;
        switch (acquired.prior_use) {
            case gpu::TextureUse.UNDEFINED:
                swapchain_before = gpu::TextureUse.UNDEFINED;
            case gpu::TextureUse.PRESENT:
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

        sample_camera::Mat4 view_proj = sample_camera::mul(
            sample_camera::perspective(
                fov_y_radians: 1.0f,
                aspect:        (float)swapchain_info.width / (float)swapchain_info.height,
                near:          0.1f,
                far:           600.0f,
            ),
            sample_camera::look_at({ 0.0f, 2.0f, 12.0f }, { 0.0f, 0.0f, -40.0f }, { 0, 1, 0 }));

        gpu::GpuSpan root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      FilterRoot::size,
            alignment: 16,
        )!;
        FilterRoot* root = (FilterRoot*)gpu::get_span_mapping(&device, root_span)!.ptr;
        write_matrix(&root.view_proj_c0, view_proj);
        root.vertex_gpu    = vertex_address;
        root.checker       = tex_index;
        root.nearest_smp   = nearest_smp;
        root.bilinear_smp  = bilinear_smp;
        root.trilinear_smp = trilinear_smp;
        root.aniso_smp     = aniso_smp;
        root.strip_width   = (float)swapchain_info.width / 4.0f;
        gpu::GpuAddress root_address = gpu::get_span_address(&device, root_span)!;

        gpu::ColorTargetDesc[1] colors = {{
            .view     = color_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.35f, 0.55f, 0.85f, 1.0f } },
        }};
        gpu::RenderPassDesc pass = {
            .colors = colors[..],
            .width  = swapchain_info.width,
            .height = swapchain_info.height,
        };
        gpu::cmd_bind_pipeline(&cmd, pipeline)!;
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::DepthState depth_state = {};
        gpu::cmd_set_depth_state(&cmd, &depth_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    root_address,
            fragment_root:  root_address,
            vertex_count:   PLANE_VERTEX_COUNT,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = {
            .texture       = acquired.texture,
            .before        = gpu::TextureUse.COLOR_ATTACHMENT,
            .after         = gpu::TextureUse.PRESENT,
        };
        gpu::cmd_texture_barrier(&cmd, &to_present)!;

        sample_frame_upload::flush_frame_upload(&upload_batch)!;
        gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
        defer (void)gpu::discard_executable_commands(&lists[0]);
        gpu::SubmitDesc submit = {
            .command_lists = lists[..],
            .readiness     = acquired.readiness,
        };
        last_graphics = gpu::submit(graphics_queue, &submit)!;
        sample_attachment_views::retire_attachment_views(
            &attachment_views,
            last_graphics,
        )!;
        sample_frame_upload::retire_frame_upload(&upload_batch, last_graphics)!;

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                device:              &device,
                producer_completion: last_graphics,
                queue_kind:          gpu::QueueKind.GRAPHICS,
                src:                 acquired.texture,
                width:       swapchain_info.width,
                height:      swapchain_info.height,
                format:      swapchain_info.format,
                from_use:    gpu::TextureUse.PRESENT,
                path:        options.screenshot_path,
            )!;
        }

        if (catch err = sample_window::present_when_ready(&device, &acquired, last_graphics)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(
                device:           &device,
                swapchain:        swapchain,
                sample:           &window,
                attachment_views: &attachment_views,
            )!;
        }

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
}
