module skybox;

import gpu;
import gpu::util;
import sample_args;
import sample_camera;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;
import std::math;

const char[*] SKY_VERT_SPIRV = $embed("shaders/sky.vert.spv");
const char[*] SKY_FRAG_SPIRV = $embed("shaders/sky.frag.spv");

const uint FACE_SIZE = 64;
const uint MIP_LEVELS = 3;
const usz UPLOAD_BYTES_PER_SLOT = SkyRoot::size;
const float FOV_Y_RADIANS = 1.1f;
const float BAND_HALF_WIDTH = 0.08f;
const float BORDER_WIDTH = 0.05f;
const float[<3>] BORDER_COLOR = { 0.9f, 0.9f, 0.9f };

// +X, -X, +Y, -Y, +Z, -Z
const float[<3>][FACE_COUNT] FACE_COLORS = {
    { 0.95f, 0.25f, 0.20f },
    { 0.20f, 0.85f, 0.90f },
    { 0.30f, 0.90f, 0.35f },
    { 0.90f, 0.30f, 0.85f },
    { 0.25f, 0.40f, 0.95f },
    { 0.95f, 0.85f, 0.25f },
};

<* Gradient along u, a diagonal bright band, and a light border; evaluated
   at the mip's own resolution so every level is authored, not filtered. *>
fn void write_face_pixels(char[] out, uint size, uint face) {
    float[<3>] base = FACE_COLORS[face];
    for (uint y = 0; y < size; y++) {
        for (uint x = 0; x < size; x++) {
            float u = ((float)x + 0.5f) / (float)size;
            float v = ((float)y + 0.5f) / (float)size;
            float[<3>] color = base * (0.35f + 0.65f * u);
            bool band = math::abs(u - v) < BAND_HALF_WIDTH;
            bool border = u < BORDER_WIDTH || u > 1.0f - BORDER_WIDTH || v < BORDER_WIDTH || v > 1.0f - BORDER_WIDTH;
            if (band) color = 0.5f + 0.5f * color;
            if (border) color = BORDER_COLOR;
            char* texel = &out[(y * size + x) * 4];
            texel[0] = (char)(color[0] * 255.0f);
            texel[1] = (char)(color[1] * 255.0f);
            texel[2] = (char)(color[2] * 255.0f);
            texel[3] = (char)255;
        }
    }
}

<* Uploads every face of every mip in one submit and waits for it. *>
fn void? upload_cube_faces(
    gpu::Device* device,
    gpu::CommandAllocator* allocator,
    gpu::TextureHandle cube,
    gpu::TextureDesc* desc,
) {
    usz total_bytes = 0;
    for (uint mip = 0; mip < MIP_LEVELS; mip++) {
        total_bytes += gpu::texture_mip_bytes(desc, mip)! * FACE_COUNT;
    }
    gpu::AllocationDesc staging_desc = {
        .size         = total_bytes,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "skybox_face_upload",
    };
    gpu::GpuAllocation staging = gpu::allocate_memory(device, &staging_desc)!;
    defer (void)gpu::free_allocation(device, &staging);
    gpu::GpuSpan staging_span = gpu::get_allocation_span(device, staging)!;

    usz offset = 0;
    for (uint mip = 0; mip < MIP_LEVELS; mip++) {
        uint size = gpu::texture_mip_dimension(FACE_SIZE, mip);
        usz face_bytes = gpu::texture_mip_bytes(desc, mip)!;
        for (uint face = 0; face < FACE_COUNT; face++) {
            gpu::GpuSpan face_span = staging_span.checked_subspan(offset, face_bytes)!;
            write_face_pixels(gpu::get_span_mapping(device, face_span)!, size, face);
            offset += face_bytes;
        }
    }
    gpu::flush_mapped_span(device, staging_span)!;

    gpu::CommandList cmd = gpu::begin_commands(allocator)!;
    defer (void)gpu::discard_commands(&cmd);
    gpu::TextureBarrier to_transfer = gpu::texture_transition(
        texture: cube,
        before:  { .layout = gpu::TextureLayout.UNDEFINED },
        after:   {
            .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
            .stages = { .transfer },
            .access = { .write },
        },
    )!;
    gpu::cmd_texture_barrier(&cmd, &to_transfer)!;

    offset = 0;
    for (uint mip = 0; mip < MIP_LEVELS; mip++) {
        usz mip_bytes = gpu::texture_mip_bytes(desc, mip)! * FACE_COUNT;
        gpu::BufferTextureCopyDesc copy = {
            .src         = staging_span.checked_subspan(offset, mip_bytes)!,
            .texture     = cube,
            .mip         = mip,
            .layer_count = FACE_COUNT,
        };
        gpu::cmd_copy_buffer_to_texture(&cmd, &copy)!;
        offset += mip_bytes;
    }

    gpu::TextureBarrier to_sample = gpu::texture_transition(
        texture: cube,
        before:  {
            .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
            .stages = { .transfer },
            .access = { .write },
        },
        after:   gpu::sampled_at({ .fragment_shader }),
    )!;
    gpu::cmd_texture_barrier(&cmd, &to_sample)!;
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::wait_completion(gpu::submit(allocator.queue, &submit)!)!;
}

fn void write_camera(SkyRoot* root, sample_camera::OrbitCamera* camera, float aspect) {
    float[<3>] pos = camera.position();
    float[<3>] forward = sample_camera::normalize(camera.target - pos);
    float[<3>] right = sample_camera::normalize(sample_camera::cross(forward, { 0.0f, 1.0f, 0.0f }));
    float[<3>] up = sample_camera::cross(right, forward);
    float tan_half_fov = math::tan(FOV_Y_RADIANS * 0.5f);
    root.camera_pos     = { pos[0], pos[1], pos[2], 0.0f };
    root.camera_right   = { right[0], right[1], right[2], 0.0f };
    root.camera_up      = { up[0], up[1], up[2], aspect };
    root.camera_forward = { forward[0], forward[1], forward[2], tan_half_fov };
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("skybox: FAIL (%s)", err);
        return 1;
    }
    io::printn("skybox: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l skybox", 800, 600)!;
    defer sample_window::destroy_sample_window(&window);

    util::DeviceContextDesc desc = util::default_device_context_desc();
    desc.runtime.enable_vulkan_validation = true;
    desc.runtime.application_name = "skybox";
    desc.create_surface = &sample_window::surface_factory;
    desc.surface_user_data = &window;
    sample_window::pixel_size(&window, &desc.swapchain.width, &desc.swapchain.height);
    desc.swapchain.present_mode = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX;
    desc.swapchain.debug_name = "skybox_swapchain";
    util::DeviceContext context = util::create_device_context(&desc)!;
    defer util::destroy_device_context(&context);
    defer (void)gpu::wait_swapchain_presentations(&context.device, context.swapchain);
    gpu::Device* device = &context.device;
    gpu::SwapchainHandle swapchain = context.swapchain;
    gpu::SwapchainInfo* swapchain_info = &context.swapchain_info;

    gpu::QueueRoles upload_access = { .graphics };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        device,
            slot_capacity: UPLOAD_BYTES_PER_SLOT,
            access:        upload_access,
            debug_name:    "skybox_frame_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

    gpu::TextureDesc cube_desc = {
        .width           = FACE_SIZE,
        .height          = FACE_SIZE,
        .mip_levels      = MIP_LEVELS,
        .array_layers    = FACE_COUNT,
        .format          = gpu::Format.RGBA8_UNORM,
        .usage           = { .sampled, .transfer_dst },
        .access          = { .graphics },
        .cube_compatible = true,
        .debug_name      = "skybox_environment",
    };
    gpu::TextureHandle cube = gpu::create_texture(device, &cube_desc)!;
    defer (void)gpu::destroy_texture(device, cube);
    upload_cube_faces(
        device:    device,
        allocator: &context.command_allocator,
        cube:      cube,
        desc:      &cube_desc,
    )!;

    gpu::TextureViewDesc cube_view_desc = { .cube = true };
    gpu::TextureView cube_view = gpu::create_texture_view(device, cube, &cube_view_desc)!;
    defer (void)gpu::destroy_texture_view(device, cube_view);

    gpu::TextureView[FACE_COUNT] face_views;
    uint face_view_count = 0;
    defer {
        for (uint i = 0; i < face_view_count; i++) (void)gpu::destroy_texture_view(device, face_views[i]);
    }
    for (uint face = 0; face < FACE_COUNT; face++) {
        gpu::TextureViewDesc face_desc = { .base_layer = face, .layer_count = 1 };
        face_views[face] = gpu::create_texture_view(device, cube, &face_desc)!;
        face_view_count++;
    }

    gpu::SamplerDesc cube_sampler_desc = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.LINEAR,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
        .max_lod    = (float)MIP_LEVELS,
    };
    gpu::SamplerIndex cube_sampler = gpu::intern_sampler(device, &cube_sampler_desc)!;
    gpu::SamplerDesc face_sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex face_sampler = gpu::intern_sampler(device, &face_sampler_desc)!;

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::ColorTargetState[1] color_targets = { gpu::color_blend_disabled() };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = { .spirv = SKY_VERT_SPIRV[..], .entry_point = "main" },
        .fragment_shader = { .spirv = SKY_FRAG_SPIRV[..], .entry_point = "main" },
        .color_formats   = color_formats[..],
        .debug_name      = "skybox",
    };
    gpu::PipelineHandle pipeline;
    bool pipeline_valid = false;
    if (!swapchain_info.dormant) {
        pipeline = gpu::create_graphics_pipeline(device, &pipe_desc)!;
        pipeline_valid = true;
    }
    defer {
        if (pipeline_valid) (void)gpu::destroy_pipeline(device, pipeline);
    }

    sample_camera::OrbitCamera camera = { .pitch = 0.25f, .radius = 3.2f, .target = { 0, 0, 0 } };

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
            *swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
        }
        if (swapchain_info.dormant) {
            sample_window::throttle_dormant();
            continue;
        }
        if (!pipeline_valid || color_formats[0] != swapchain_info.format) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
            if (pipeline_valid) gpu::destroy_pipeline(device, pipeline)!;
            pipeline_valid = false;
            color_formats[0] = swapchain_info.format;
            pipeline = gpu::create_graphics_pipeline(device, &pipe_desc)!;
            pipeline_valid = true;
        }

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(
            device:     device,
            swapchain:  swapchain,
            timeout_ns: sample_window::FRAME_ACQUIRE_TIMEOUT_NS,
        );
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) *swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
            continue;
        }

        sample_frame_upload::FrameUploadBatch upload_batch =
            sample_frame_upload::begin_frame_upload(&upload_ring)!;
        defer catch {
            if (upload_batch.ring != null) {
                (void)sample_frame_upload::cancel_frame_upload(&upload_batch);
            }
        };

        gpu::CommandList cmd = gpu::begin_commands(&context.command_allocator)!;
        defer (void)gpu::discard_commands(&cmd);

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

        float time = (float)frame / 60.0f;
        camera.yaw = time * 1.2f;
        camera.pitch = 0.25f + 0.2f * math::sin(time * 0.7f);

        gpu::GpuSpan root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      SkyRoot::size,
            alignment: 16,
        )!;
        SkyRoot* root = (SkyRoot*)gpu::get_span_mapping(device, root_span)!.ptr;
        write_camera(root, &camera, (float)swapchain_info.width / (float)swapchain_info.height);
        root.cube         = cube_view.index;
        root.cube_sampler = cube_sampler;
        root.face_sampler = face_sampler;
        root.mip_count    = MIP_LEVELS;
        for (uint face = 0; face < FACE_COUNT; face++) root.faces[face] = face_views[face].index;
        root.time = time;
        gpu::GpuAddress root_address = gpu::get_span_address(device, root_span)!;

        gpu::ColorTargetDesc[1] colors = {{
            .view     = acquired.attachment_view,
            .load_op  = gpu::LoadOp.DONT_CARE,
            .store_op = gpu::StoreOp.STORE,
        }};
        gpu::RenderPassDesc pass = {
            .colors = colors[..],
            .width  = swapchain_info.width,
            .height = swapchain_info.height,
        };
        gpu::GraphicsState graphics = gpu::render_geometry_state(pass.width, pass.height)!;
        graphics.color.targets = color_targets[..];
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::cmd_bind_pipeline(&cmd, pipeline)!;
        gpu::cmd_set_graphics_state(&cmd, &graphics)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    root_address,
            fragment_root:  root_address,
            vertex_count:   3,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = gpu::texture_transition(
            texture: acquired.texture,
            before:  {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
            after:   { .layout = gpu::TextureLayout.PRESENT },
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_present)!;

        sample_frame_upload::flush_frame_upload(&upload_batch)!;
        gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
        defer (void)gpu::discard_executable_commands(&lists[0]);
        gpu::SubmitDesc submit = {
            .command_lists    = lists[..],
            .readiness        = acquired.readiness,
            .readiness_before = { .color_output },
        };
        last_graphics = gpu::submit(context.queue, &submit)!;
        sample_frame_upload::retire_frame_upload(&upload_batch, last_graphics)!;

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                allocator:           &context.command_allocator,
                producer_completion: last_graphics,
                src:                 acquired.texture,
                width:               swapchain_info.width,
                height:              swapchain_info.height,
                format:              swapchain_info.format,
                from_state:          { .layout = gpu::TextureLayout.PRESENT },
                path:                options.screenshot_path,
            )!;
        }

        if (catch err = sample_window::present_when_ready(device, &acquired, last_graphics)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            *swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
        }

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
}
