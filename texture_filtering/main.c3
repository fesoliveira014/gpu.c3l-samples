module texture_filtering;

import gpu;
import sample_args;
import sample_camera;
import sample_capture;
import sample_window;
import std::io;

const char[*] PLANE_VERT_SPIRV = $embed("shaders/plane.vert.spv");
const char[*] PLANE_FRAG_SPIRV = $embed("shaders/plane.frag.spv");

const uint TEX_SIZE = 256;
const uint MIP_LEVELS = 9;
const uint CHECKER_CELLS = 8;

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
    return gpu::create_sampler(device, &desc);
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

    gpu::DeviceDesc device_desc = {
        .backend             = gpu::BackendKind.VULKAN,
        .enable_validation   = true,
        .enable_presentation = true,
        .frames_in_flight    = 2,
        .application_name    = "texture_filtering",
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
        .debug_name       = "filtering_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)gpu::destroy_swapchain(&device, swapchain);

    gpu::BufferDesc vertex_desc = {
        .size        = PLANE_VERTEX_BYTES,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = "plane_vertices",
    };
    gpu::BufferHandle vertices = gpu::create_buffer(&device, &vertex_desc)!;
    defer (void)gpu::destroy_buffer(&device, vertices);
    gpu::GpuSpan vertex_span = gpu::get_buffer_span(&device, vertices)!;
    write_plane_vertices((float*)vertex_span.cpu);
    gpu::flush_buffer(&device, vertices, 0, 0)!;

    gpu::TextureDesc tex_desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = TEX_SIZE,
        .height     = TEX_SIZE,
        .mip_levels = MIP_LEVELS,
        .format     = gpu::Format.RGBA8_UNORM,
        .usage      = { .sampled, .transfer_dst },
        .debug_name = "tinted_checker",
    };
    gpu::TextureHandle checker = gpu::create_texture(&device, &tex_desc)!;
    defer (void)gpu::destroy_texture(&device, checker);

    for (uint level = 0; level < MIP_LEVELS; level++) {
        uint level_size = TEX_SIZE >> level;
        if (level_size == 0) level_size = 1;
        char[] pixels = mem::new_array(char, (sz)((usz)level_size * level_size * 4));
        defer free(pixels.ptr);
        write_mip_pixels(pixels, level_size, level);
        bool last = level == MIP_LEVELS - 1;
        gpu::upload_texture_data(
            device:      &device,
            dst:         checker,
            mip:         level,
            data:        pixels,
            next_stage:  last ? gpu::Stage.FRAGMENT_SHADER : gpu::Stage.TRANSFER,
            next_hazard: last ? gpu::Hazard.SHADER_READ : gpu::Hazard.TRANSFER_WRITE,
            next_layout: last ? gpu::TextureLayout.SHADER_READ : gpu::TextureLayout.TRANSFER_DST,
        )!;
    }
    gpu::TextureIndex tex_index = gpu::create_texture_descriptor(&device, checker, null)!;
    defer (void)gpu::destroy_texture_descriptor(&device, tex_index);

    gpu::SamplerIndex nearest_smp = make_sampler(&device, gpu::Filter.NEAREST, gpu::Filter.NEAREST, 0.0f)!;
    defer (void)gpu::destroy_sampler(&device, nearest_smp);
    gpu::SamplerIndex bilinear_smp = make_sampler(&device, gpu::Filter.LINEAR, gpu::Filter.NEAREST, 0.0f)!;
    defer (void)gpu::destroy_sampler(&device, bilinear_smp);
    gpu::SamplerIndex trilinear_smp = make_sampler(&device, gpu::Filter.LINEAR, gpu::Filter.NEAREST, (float)MIP_LEVELS)!;
    defer (void)gpu::destroy_sampler(&device, trilinear_smp);
    gpu::SamplerIndex aniso_smp = make_sampler(&device, gpu::Filter.LINEAR, gpu::Filter.LINEAR, (float)MIP_LEVELS, aniso: device.caps.max_sampler_anisotropy > 0)!;
    defer (void)gpu::destroy_sampler(&device, aniso_smp);

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = PLANE_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle vert = gpu::create_shader(&device, &vert_sd)!;
    defer (void)gpu::destroy_shader(&device, vert);
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = PLANE_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle frag = gpu::create_shader(&device, &frag_sd)!;
    defer (void)gpu::destroy_shader(&device, frag);

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
    while (running) {
        sample_window::WindowEvents events = sample_window::pump_events(&window);
        if (events.quit) break;
        if (events.resized) {
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
        }
        if (swapchain_info.dormant) continue;
        if (!pipeline_valid || color_formats[0] != swapchain_info.format) {
            gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
            if (pipeline_valid) gpu::destroy_pipeline(&device, pipeline)!;
            pipeline_valid = false;
            color_formats[0] = swapchain_info.format;
            pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
            pipeline_valid = true;
        }

        gpu::begin_frame(&device)!;

        gpu::AcquiredImage acquired;
        if (try image = gpu::acquire_next_image(&device, swapchain)) {
            acquired = image;
        } else {
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
            gpu::end_frame(&device)!;
            continue;
        }

        gpu::CommandList cmd = gpu::begin_commands(&device, gpu::QueueKind.GRAPHICS)!;

        gpu::TextureUse swapchain_before;
        switch (acquired.prior_layout) {
            case gpu::TextureLayout.UNDEFINED:
                swapchain_before = gpu::TextureUse.UNDEFINED;
            case gpu::TextureLayout.PRESENT:
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

        gpu::GpuSpan root_span = gpu::alloc_frame_span(&device, FilterRoot::size, 16)!;
        FilterRoot* root = (FilterRoot*)root_span.cpu;
        write_matrix(&root.view_proj_c0, view_proj);
        root.vertex_gpu    = vertex_span.gpu;
        root.checker       = tex_index;
        root.nearest_smp   = nearest_smp;
        root.bilinear_smp  = bilinear_smp;
        root.trilinear_smp = trilinear_smp;
        root.aniso_smp     = aniso_smp;
        root.strip_width   = (float)swapchain_info.width / 4.0f;

        gpu::ColorTargetDesc[1] colors = {{
            .texture  = acquired.texture,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.35f, 0.55f, 0.85f, 1.0f } },
        }};
        gpu::RenderPassDesc pass = {
            .colors = colors[..],
            .width  = swapchain_info.width,
            .height = swapchain_info.height,
        };
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::cmd_draw(
            commands:       &cmd,
            pipeline:       pipeline,
            vertex_root:    root_span.gpu,
            fragment_root:  root_span.gpu,
            vertex_count:   PLANE_VERTEX_COUNT,
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
                width:       swapchain_info.width,
                height:      swapchain_info.height,
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

        gpu::end_frame(&device)!;

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
}
